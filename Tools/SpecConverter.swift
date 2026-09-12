import Foundation
import JavaScriptCore

/// Turns Fig's completion specs into the compact JSON the app reads.
///
/// The specs ship as TypeScript, compiled by esbuild into one self-contained
/// JavaScript bundle per command. There is no node on this device that runs,
/// but there is JavaScriptCore, which is a system framework: each bundle is
/// evaluated in a fresh `JSContext`, and a small JavaScript function walks the
/// resulting object and keeps only the structure — names, subcommands,
/// options, arguments and their templates. Descriptions, icons, generators
/// (shell commands Fig runs for dynamic values) and every other function are
/// dropped: ghost text shows one completed line, not a menu, and JSON cannot
/// hold a function anyway.
///
/// Run from the harness: `harness --specs <fig-build-dir> <out-dir>`. The
/// output is checked in, so an ordinary build needs neither the package nor
/// this converter.
///
/// The specs are Fig's, under the MIT licence — see Resources/Specs/LICENSE.
/// This file, and the engine that reads the output, are ours.
enum SpecConverter {

    struct Result {
        var written: [String] = []
        var failed: [(name: String, reason: String)] = []
        var bytes = 0
        var packedBytes = 0
    }

    /// Minimal globals some bundles touch at load time. None of them are
    /// used for anything that matters here; they exist so evaluation does
    /// not throw before the spec object is built.
    private static let prelude = """
    var window = globalThis;
    var self = globalThis;
    var process = { env: {}, platform: "darwin", versions: {}, cwd: function () { return "/"; } };
    var console = { log: function () {}, warn: function () {}, error: function () {} };
    var fetch = function () { return Promise.reject(new Error("no network")); };
    var navigator = { userAgent: "" };
    var require = function () { return {}; };
    """

    /// Walks a spec object and returns the compact shape.
    ///
    /// Short keys, because the output ships in the app. Node: `n` names,
    /// `s` subcommands, `o` options, `a` args, `h` hidden, `d` deprecated,
    /// `p` priority. Option: `n`, `a`, `r` repeatable, `q` requires-separator,
    /// `h`, `d`, `p`. Arg: `n` name, `o` optional, `v` variadic, `c` is a
    /// command, `t` templates, `g` static suggestions.
    private static let compactor = """
    (function () {
      function names(n) { return n == null ? [] : (Array.isArray(n) ? n : [n]).map(String).filter(function (s) { return s.length > 0; }); }
      function list(x) { return x == null ? [] : (Array.isArray(x) ? x : [x]); }
      function arg(a) {
        if (!a || typeof a !== "object") return null;
        var out = {};
        var n = names(a.name); if (n.length) out.n = n[0];
        if (a.isOptional) out.o = 1;
        if (a.isVariadic) out.v = 1;
        if (a.isCommand) out.c = 1;
        var t = names(a.template); if (t.length) out.t = t;
        var g = list(a.suggestions).map(function (x) { return typeof x === "string" ? x : (x && names(x.name)[0]); }).filter(Boolean);
        if (g.length) out.g = g;
        return out;
      }
      function option(o) {
        if (!o || typeof o !== "object") return null;
        var out = { n: names(o.name) };
        if (!out.n.length) return null;
        var a = list(o.args).map(arg).filter(Boolean); if (a.length) out.a = a;
        if (o.isRepeatable) out.r = 1;
        if (o.requiresSeparator) out.q = typeof o.requiresSeparator === "string" ? o.requiresSeparator : "=";
        if (o.hidden) out.h = 1;
        if (o.deprecated) out.d = 1;
        if (typeof o.priority === "number") out.p = o.priority;
        return out;
      }
      function node(s, depth) {
        if (!s || typeof s !== "object") return null;
        var out = { n: names(s.name) };
        if (!out.n.length) return null;
        if (depth < 6) {
          var subs = list(s.subcommands).map(function (x) { return node(x, depth + 1); }).filter(Boolean);
          if (subs.length) out.s = subs;
        }
        var o = list(s.options).map(option).filter(Boolean); if (o.length) out.o = o;
        var a = list(s.args).map(arg).filter(Boolean); if (a.length) out.a = a;
        if (s.hidden) out.h = 1;
        if (s.deprecated) out.d = 1;
        if (typeof s.priority === "number") out.p = s.priority;
        return out;
      }
      var spec = globalThis.__spec;
      if (spec && typeof spec === "object" && spec.default && typeof spec.default === "object") spec = spec.default;
      var compact = node(spec, 0);
      return compact ? JSON.stringify(compact) : "";
    })()
    """

    static func convert(from inputDirectory: String, to outputDirectory: String) -> Result {
        var result = Result()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        guard let entries = try? fm.contentsOfDirectory(atPath: inputDirectory) else {
            result.failed.append(("", "cannot list \(inputDirectory)"))
            return result
        }

        // Only names a shell could be asked to complete. The scoped-package
        // directories (`@fig/`, `@capgo/`…) hold specs for `npx`-style
        // invocations that never appear as a first word.
        let valid = try! NSRegularExpression(pattern: "^[A-Za-z0-9_][A-Za-z0-9_.+-]*$")
        // `default` can sit anywhere in the export list — npm, yarn, ssh, aws
        // and clang all put a named export first — so the list is captured
        // whole and the default found inside it.
        let exportPattern = try! NSRegularExpression(pattern: "export\\s*\\{([^}]*)\\}\\s*;?\\s*$")
        let defaultPattern = try! NSRegularExpression(pattern: "([A-Za-z0-9_$]+)\\s+as\\s+default\\b")
        try? fm.createDirectory(atPath: outputDirectory + "/packed", withIntermediateDirectories: true)

        for file in entries.sorted() where file.hasSuffix(".js") {
            let name = String(file.dropLast(3))
            // The package's own index is not a command.
            guard name != "index" else { continue }
            let range = NSRange(name.startIndex..., in: name)
            guard valid.firstMatch(in: name, range: range) != nil else { continue }

            guard var source = try? String(contentsOfFile: inputDirectory + "/" + file, encoding: .utf8) else {
                result.failed.append((name, "unreadable"))
                continue
            }

            // `export { X as default }` is module syntax JavaScriptCore's
            // script evaluator does not accept. Rewrite it into an assignment
            // the compactor can find.
            let sourceRange = NSRange(source.startIndex..., in: source)
            guard let match = exportPattern.firstMatch(in: source, range: sourceRange),
                  let listRange = Range(match.range(at: 1), in: source),
                  let wholeRange = Range(match.range, in: source) else {
                result.failed.append((name, "no export list"))
                continue
            }
            let list = String(source[listRange])
            guard let hit = defaultPattern.firstMatch(in: list, range: NSRange(list.startIndex..., in: list)),
                  let identifierRange = Range(hit.range(at: 1), in: list) else {
                result.failed.append((name, "no default export"))
                continue
            }
            let identifier = String(list[identifierRange])
            source.replaceSubrange(wholeRange, with: "globalThis.__spec = \(identifier);")

            guard let context = JSContext() else {
                result.failed.append((name, "no JSContext"))
                continue
            }
            var exception: String?
            context.exceptionHandler = { _, value in
                exception = value?.toString() ?? "unknown exception"
            }

            context.evaluateScript(prelude)
            context.evaluateScript(source)
            if let exception {
                result.failed.append((name, exception))
                continue
            }

            let json = context.evaluateScript(compactor)?.toString() ?? ""
            if let exception {
                result.failed.append((name, "compact: " + exception))
                continue
            }
            guard !json.isEmpty, json != "undefined" else {
                result.failed.append((name, "empty spec"))
                continue
            }

            let path = outputDirectory + "/" + name + ".json"
            do {
                try json.write(toFile: path, atomically: true, encoding: .utf8)
                result.written.append(name)
                result.bytes += json.utf8.count
            } catch {
                result.failed.append((name, "write: \(error.localizedDescription)"))
                continue
            }
            // The packed copy is what ships: the JSON deflates about seven
            // times, which is the difference between 3.6 MB and half a
            // megabyte for all seven hundred tools.
            if let packed = SpecStore.pack(json) {
                try? packed.write(to: URL(fileURLWithPath: outputDirectory + "/packed/" + name + ".z"))
                result.packedBytes += packed.count
            }
        }
        return result
    }
}
