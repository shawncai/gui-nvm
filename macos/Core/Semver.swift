import Foundation
import JavaScriptCore

/// Runs only the reviewed, bundled node-semver source. Project files remain data.
public final class Semver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "gui-nvm.semver")
    private let context: JSContext

    /// resourceURL is the vendored node-semver directory containing index.js.
    public init(resourceURL: URL) throws {
        let root = try SafeFile.directory(resourceURL.path)
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw AppError("缺少内置 semver 资源")
        }
        var modules: [String: String] = [:]
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, file.pathExtension == "js", file.path.hasPrefix(root + "/") else { continue }
            let name = String(file.path.dropFirst(root.count + 1))
            modules[name] = try SafeFile.read(file.path)
        }
        guard modules["index.js"] != nil else { throw AppError("缺少内置 semver/index.js") }
        let encoded = try JSONSerialization.data(withJSONObject: modules, options: [.sortedKeys])
        guard let sourceMap = String(data: encoded, encoding: .utf8), let js = JSContext() else { throw AppError("无法初始化版本解析器") }
        context = js
        let bootstrap = """
        (() => {
          'use strict';
          const sources = \(sourceMap);
          const cache = Object.create(null);
          function resolve(parent, request) {
            if (typeof request !== 'string' || !(request.startsWith('./') || request.startsWith('../'))) throw new Error('Only bundled relative modules are allowed');
            const segments = parent.split('/'); segments.pop();
            for (const part of request.split('/')) {
              if (part === '' || part === '.') continue;
              if (part === '..') { if (!segments.length) throw new Error('Module path escapes bundle'); segments.pop(); }
              else segments.push(part);
            }
            let id = segments.join('/');
            if (!id.endsWith('.js')) id += '.js';
            if (!Object.prototype.hasOwnProperty.call(sources, id)) throw new Error('Missing bundled module: ' + id);
            return id;
          }
          function load(id) {
            if (cache[id]) return cache[id].exports;
            const module = { exports: {} };
            cache[id] = module;
            try { new Function('require', 'module', 'exports', sources[id])(request => load(resolve(id, request)), module, module.exports); }
            catch (error) { delete cache[id]; throw error; }
            return module.exports;
          }
          globalThis.__guiSemver = load('index.js');
          globalThis.__guiRewriteManifest = (text, requested) => {
            let manifest;
            try { manifest = JSON.parse(text); } catch (_) { throw new Error('package.json 格式错误'); }
            if (!manifest || Array.isArray(manifest) || typeof manifest !== 'object') throw new Error('package.json 必须是对象');
            const indentation = text.match(/\\n([ \\t]+)"/)?.[1] || '  ';
            manifest.engines = { ...(typeof manifest.engines === 'object' && manifest.engines !== null ? manifest.engines : {}), node: requested };
            return JSON.stringify(manifest, null, indentation) + '\\n';
          };
        })();
        """
        try queue.sync {
            js.evaluateScript(bootstrap)
            if let exception = js.exception { throw AppError("版本解析器初始化失败：\(exception.toString() ?? "未知错误")") }
        }
    }

    public func validRange(_ range: String) -> String? {
        queue.sync {
            context.exception = nil
            let result = context.objectForKeyedSubscript("__guiSemver")?.objectForKeyedSubscript("validRange")?.call(withArguments: [range])
            guard context.exception == nil, let result, !result.isNull, !result.isUndefined else { return nil }
            return result.toString()
        }
    }

    public func satisfies(_ version: String, _ range: String) -> Bool {
        queue.sync {
            context.exception = nil
            let result = context.objectForKeyedSubscript("__guiSemver")?.objectForKeyedSubscript("satisfies")?.call(withArguments: [version, range])
            return context.exception == nil && result?.toBool() == true
        }
    }

    public func rcompare(_ left: String, _ right: String) -> Int {
        queue.sync {
            context.exception = nil
            let result = context.objectForKeyedSubscript("__guiSemver")?.objectForKeyedSubscript("rcompare")?.call(withArguments: [left, right])
            return context.exception == nil ? Int(result?.toInt32() ?? 0) : 0
        }
    }

    public func rewriteManifest(_ text: String, requested: String) throws -> String {
        try queue.sync {
            context.exception = nil
            let result = context.objectForKeyedSubscript("__guiRewriteManifest")?.call(withArguments: [text, requested])
            if let exception = context.exception { throw AppError(exception.toString() ?? "package.json 写入失败") }
            guard let result, !result.isUndefined, let output = result.toString() else { throw AppError("package.json 写入失败") }
            return output
        }
    }
}
