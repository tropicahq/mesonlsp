import Dispatch
import Foundation
import IOUtils
import LanguageServerProtocol
import Logging
import MesonAnalyze
import MesonAST
import MesonDocs
import Timing

#if !os(Windows)
  import Atomics
#endif
#if os(Linux)
  import Swifter
#endif

// There seem to be some name collisions
public typealias MesonVoid = ()

public final class MesonServer: LanguageServer {
  static let LOG = Logger(label: "LanguageServer::MesonServer")
  static let MIN_PORT = 65000
  static let MAX_PORT = 65550
  var onExit: () -> MesonVoid
  var path: String?
  var tree: MesonTree?
  var ns: TypeNamespace
  var memfiles: [String: String] = [:]
  #if os(Linux)
    var server: HttpServer
  #endif
  var docs: MesonDocs = MesonDocs()
  var openFiles: Set<String> = []
  var astCache: [String: Node] = [:]
  #if !os(Windows)
    let lastAskedForRebuild = ManagedAtomic<UInt64>(0)
  #else
    // Windows will be a bit buggy, but as long as it works
    var lastAskedForRebuild = 0
  #endif
  let interval = DispatchTimeInterval.seconds(60)

  public init(client: Connection, onExit: @escaping () -> MesonVoid) {
    self.onExit = onExit
    self.ns = TypeNamespace()
    #if os(Linux)
      self.server = HttpServer()
      for i in Self.MIN_PORT...Self.MAX_PORT {
        do {
          try self.server.start(
            in_port_t(i),
            forceIPv4: false,
            priority: DispatchQoS.QoSClass.background
          )
          Self.LOG.info("Port: \(i)")
          break
        } catch {}
      }
      super.init(client: client)
      self.server["/"] = { _ in return HttpResponse.ok(.text(self.generateHTML())) }
    #else
      super.init(client: client)
    #endif
    self.queue.asyncAfter(deadline: .now() + interval) {
      self.sendStats()
      self.scheduleNextTask()
    }
  }

  private func sendStats() {
    #if os(Linux)
      Self.LOG.info("Collecting stats")
      let stats = collectStats()
      let heap = stats[0]
      let stack = stats[1]
      let total = stats[2]
      let heapS = formatWithUnits(heap)
      let stackS = formatWithUnits(stack)
      let totalS = formatWithUnits(total)
      Self.LOG.info("Stack: \(stackS) Heap: \(heapS) Total: \(totalS)")
    #endif
  }

  private func scheduleNextTask() {
    self.queue.asyncAfter(deadline: .now() + interval) {
      self.sendStats()
      self.scheduleNextTask()
    }
  }

  public func prepareForExit() {

  }

  public override func _registerBuiltinHandlers() {
    _register(Self.initialize)
    _register(Self.clientInitialized)
    _register(Self.cancelRequest)
    _register(Self.shutdown)
    _register(Self.exit)
    _register(Self.openDocument)
    _register(Self.closeDocument)
    _register(Self.changeDocument)
    _register(Self.didSaveDocument)
    _register(Self.hover)
    _register(Self.declaration)
    _register(Self.definition)
    _register(Self.formatting)
    _register(Self.documentSymbol)
    _register(Self.complete)
    _register(Self.highlight)
    _register(Self.inlayHints)
    _register(Self.didCreateFiles)
    _register(Self.didDeleteFiles)
  }

  private func inlayHints(_ req: Request<InlayHintRequest>) {
    let begin = clock()
    let file = req.params.textDocument.uri.fileURL!.path
    if let t = self.tree, let mt = t.findSubdirTree(file: file), let ast = mt.ast {
      let ih = InlayHints()
      ast.visit(visitor: ih)
      req.reply(ih.inlays)
      Timing.INSTANCE.registerMeasurement(name: "inlayHints", begin: begin, end: clock())
      return
    }
    Timing.INSTANCE.registerMeasurement(name: "inlayHints", begin: begin, end: clock())
    req.reply([])
  }

  private func highlight(_ req: Request<DocumentHighlightRequest>) {
    let begin = clock()
    let file = req.params.textDocument.uri.fileURL!.path
    if let t = self.tree, let mt = t.findSubdirTree(file: file), let ast = mt.ast,
      let id = self.tree!.metadata!.findIdentifierAt(
        file,
        req.params.position.line,
        req.params.position.utf16index
      )
    {
      let hs = HighlightSearcher(varname: id.id)
      ast.visit(visitor: hs)
      var ret: [DocumentHighlight] = []
      for a in hs.accesses {
        let accessType: DocumentHighlightKind = a.0 == 2 ? .read : .write
        let si = a.1
        let range =
          Position(
            line: Int(si.startLine),
            utf16index: Int(si.startColumn)
          )..<Position(line: Int(si.endLine), utf16index: Int(si.endColumn))
        ret.append(DocumentHighlight(range: range, kind: accessType))
      }
      Timing.INSTANCE.registerMeasurement(name: "highlight", begin: begin, end: clock())
      req.reply(ret)
      return
    }
    Timing.INSTANCE.registerMeasurement(name: "highlight", begin: begin, end: clock())
    req.reply([])
  }

  private func complete(_ req: Request<CompletionRequest>) {
    let begin = clock()
    var arr: [CompletionItem] = []
    let fp = req.params.textDocument.uri.fileURL!.path
    if let t = self.tree, let mt = t.findSubdirTree(file: fp), mt.ast != nil,
      let content = self.getContents(file: fp)
    {
      let pos = req.params.position
      let line = pos.line
      let column = pos.utf16index
      let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      Self.LOG.info("Completion at: [\(line):\(column)]")
      if line < lines.count && lines[line].trimmingCharacters(in: .whitespaces).count >= 1 {
        let str = lines[line]
        let prev = str.prefix(column + 1).description.trimmingCharacters(in: .whitespaces)
        if prev.hasSuffix("."), let t = self.tree, let md = t.metadata {
          let exprTypes = self.afterDotCompletion(md, fp, line, column)
          if let types = exprTypes {
            let s: Set<Method> = self.fillTypes(types)
            for c in s {
              arr.append(
                CompletionItem(
                  label: c.name,
                  kind: .method,
                  insertText: createTextForFunction(c),
                  insertTextFormat: .snippet
                )
              )
            }
          }
        } else if let t = self.tree, let md = t.metadata {
          if let idexpr = md.findIdentifierAt(fp, line, column),
            let al = idexpr.parent as? ArgumentList
          {
            let callExpr = idexpr.parent!.parent!
            let usedKwargs: Set<String> = self.enumerateUsedKwargs(al)
            let s: Set<String> = self.fillKwargs(callExpr)
            for c in s where !usedKwargs.contains(c) {
              arr.append(
                CompletionItem(
                  label: c,
                  kind: .keyword,
                  insertText: "\(c): ${1:\(c)}",
                  insertTextFormat: .snippet
                )
              )
            }
          } else if let idexpr = md.findIdentifierAt(fp, line, column) {
            let currId = idexpr.id
            for f in self.ns.functions where f.name.lowercased().contains(currId.lowercased()) {
              arr.append(
                CompletionItem(
                  label: f.name,
                  kind: .function,
                  insertText: createTextForFunction(f),
                  insertTextFormat: .snippet
                )
              )
            }
          } else {
            finalAttempt(prev, line, fp, md, &arr)
          }
        }
      } else {
        Self.LOG.error("Line out of bounds: \(line) > \(lines.count)")
      }  // 1. Get the nearest node
      // 2. If it is an identifier and parent is build_definition/iterS/selectS
      // 2.1. Calculate function names
      // 2.2. Calculate matching identifier names
      // 3. If it is an identifier and parent is keyworditem/methodcall/functionexpression
      // 3.1. Calculate, whether it matches kwargs
      // 4. If it is an expression like this "<sth>.", attempt to deduce the methods
      // of <sth>
    }
    req.reply(CompletionList(isIncomplete: false, items: arr))
    Timing.INSTANCE.registerMeasurement(name: "complete", begin: begin, end: clock())
  }

  private func finalAttempt(
    _ prev: String,
    _ line: Int,
    _ fp: String,
    _ md: MesonMetadata,
    _ arr: inout [CompletionItem]
  ) {
    var n = prev.count - 1
    var invalid = false
    while prev[n] != "." && n >= 0 {
      Self.LOG.info("Finalcompletion: \(prev[0..<n])")
      if prev[n].isNumber || prev[n] == " " {
        invalid = true
        break
      }
      n -= 1
      if n == -1 {
        invalid = true
        break
      }
    }
    if invalid { return }
    let exprTypes = self.afterDotCompletion(md, fp, line, n)
    // The editor should filter this client side
    if let types = exprTypes {
      let s: Set<Method> = self.fillTypes(types)
      for c in s {
        arr.append(
          CompletionItem(
            label: c.name,
            kind: .method,
            insertText: createTextForFunction(c),
            insertTextFormat: .snippet
          )
        )
      }
    }
  }

  private func createTextForFunction(_ m: Function) -> String {
    var str = m.name + "("
    var n = 1
    for arg in m.args where arg is PositionalArgument {
      let p = (arg as! PositionalArgument)
      if !p.opt {
        str += "${\(n):\(p.name)}, "
        n += 1
      }
    }
    for arg in m.args where arg is Kwarg {
      let p = (arg as! Kwarg)
      if !p.opt {
        str += "\(p.name): ${\(n):\(p.name)}, "
        n += 1
      }
    }
    return (str + ")").replacingOccurrences(of: ", )", with: ")")
  }

  private func fillTypes(_ types: [Type]) -> Set<Method> {
    var s: Set<Method> = []
    for t in types {
      for m in self.ns.vtables[t.name]! {
        Self.LOG.info("Inserting completion: \(m.name)")
        s.insert(m)
      }
      if let t1 = t as? AbstractObject {
        var p = t1.parent
        while p != nil {
          for m in self.ns.vtables[p!.name]! {
            Self.LOG.info("Inserting completion: \(m.name)")
            s.insert(m)
          }
          p = p!.parent
        }
      }
    }
    return s
  }

  private func fillKwargs(_ callExpr: Node) -> Set<String> {
    var s: Set<String> = []
    if let fe = callExpr as? FunctionExpression, let f = fe.function {
      for arg in f.args where arg is Kwarg {
        Self.LOG.info("Adding kwarg to completion list: \((arg as! Kwarg).name)")
        s.insert((arg as! Kwarg).name)
      }
    } else if let me = callExpr as? MethodExpression, let m = me.method {
      for arg in m.args where arg is Kwarg {
        Self.LOG.info("Adding kwarg to completion list: \((arg as! Kwarg).name)")
        s.insert((arg as! Kwarg).name)
      }
    }
    return s
  }

  private func enumerateUsedKwargs(_ al: ArgumentList) -> Set<String> {
    var usedKwargs: Set<String> = []
    for arg in al.args where arg is KeywordItem {
      let kwi = (arg as! KeywordItem)
      let kwik = (kwi.key as! IdExpression)
      Self.LOG.info("Found already used kwarg: \(kwik.id)")
      usedKwargs.insert(kwik.id)
    }
    return usedKwargs
  }

  private func afterDotCompletion(_ md: MesonMetadata, _ fp: String, _ line: Int, _ column: Int)
    -> [Type]?
  {
    if let idexpr = md.findIdentifierAt(fp, line, column - 1) {
      Self.LOG.info("Found id expr: \(idexpr.id)")
      return idexpr.types
    } else if let fc = md.findFullFunctionCallAt(fp, line, column - 1), fc.function != nil {
      Self.LOG.info("Found function expr: \(fc.functionName())")
      return fc.types
    } else if let me = md.findFullMethodCallAt(fp, line, column - 1), me.method != nil {
      Self.LOG.info("Found method expr: \(me.method!.id())")
      return me.types
    }
    return nil
  }

  private func documentSymbol(_ req: Request<DocumentSymbolRequest>) {
    let begin = clock()
    if let t = self.tree,
      let mt = t.findSubdirTree(file: req.params.textDocument.uri.fileURL!.path), let ast = mt.ast
    {
      let sv = SymbolCodeVisitor()
      var rep: [SymbolInformation] = []
      ast.visit(visitor: sv)
      for si in sv.symbols {
        let name = si.name
        let range =
          Position(
            line: Int(si.startLine),
            utf16index: Int(si.startColumn)
          )..<Position(line: Int(si.endLine), utf16index: Int(si.endColumn))
        let kind = SymbolKind(rawValue: Int(si.kind))
        rep.append(
          SymbolInformation(
            name: name,
            kind: kind,
            location: Location(uri: req.params.textDocument.uri, range: range)
          )
        )
      }
      req.reply(.symbolInformation(rep))
      Timing.INSTANCE.registerMeasurement(name: "documentSymbol", begin: begin, end: clock())
      return
    }
    req.reply(.symbolInformation([]))
    Timing.INSTANCE.registerMeasurement(name: "documentSymbol", begin: begin, end: clock())
  }

  private func formatting(_ req: Request<DocumentFormattingRequest>) {
    let begin = clock()
    do {
      Self.LOG.info("Formatting \(req.params.textDocument.uri.fileURL!.path)")
      if let contents = self.getContents(file: req.params.textDocument.uri.fileURL!.path) {
        if let formatted = try formatFile(content: contents, params: req.params.options) {
          let newLines = formatted.split(whereSeparator: \.isNewline)
          let endOfLastLine = newLines.isEmpty ? 1024 : (newLines[newLines.count - 1].count)
          let range =
            Position(
              line: 0,
              utf16index: 0
            )..<Position(line: newLines.count + 2048, utf16index: endOfLastLine)
          let edit = TextEdit(range: range, newText: formatted)
          req.reply([edit])
          Timing.INSTANCE.registerMeasurement(name: "formatting", begin: begin, end: clock())
          return
        } else {
          Self.LOG.error("Unable to format file")
        }
      } else {
        Self.LOG.error("Unable to read file")
      }
    } catch {
      Self.LOG.error("Error formatting file \(error)")
      req.reply(
        Result.failure(
          ResponseError(code: .internalError, message: "Unable to format using muon: \(error)")
        )
      )
      Timing.INSTANCE.registerMeasurement(name: "formatting", begin: begin, end: clock())
      return
    }
    req.reply(
      Result.failure(
        ResponseError(
          code: .internalError,
          message: "Either failed to read the input file or to format using muon"
        )
      )
    )
    Timing.INSTANCE.registerMeasurement(name: "formatting", begin: begin, end: clock())
  }

  private func getContents(file: String) -> String? {
    if let sf = self.memfiles[file] { return sf }
    return try? String(contentsOfFile: file)
  }

  private func hoverFindCallable(
    _ file: String,
    _ line: Int,
    _ column: Int,
    _ function: inout Function?,
    _ content: inout String?
  ) {
    if let m = self.tree!.metadata!.findMethodCallAt(file, line, column), m.method != nil {
      function = m.method!
      content = m.method!.parent.toString() + "." + m.method!.name
    }
    if content == nil, let f = self.tree!.metadata!.findFunctionCallAt(file, line, column),
      f.function != nil
    {
      function = f.function!
      content = f.function!.name
    }
  }

  private func hoverFindIdentifier(
    _ file: String,
    _ line: Int,
    _ column: Int,
    _ content: inout String?,
    _ requery: inout Bool
  ) {
    if content == nil, let f = self.tree!.metadata!.findIdentifierAt(file, line, column) {
      if !f.types.isEmpty {
        content = f.types.map { $0.toString() }.joined(separator: "|")
        requery = false
      }
    }
  }

  private func hover(_ req: Request<HoverRequest>) {
    let begin = clock()
    let location = req.params.position
    let file = req.params.textDocument.uri.fileURL?.path
    var content: String?
    var requery = true
    var function: Function?
    var kwargTypes: String?
    self.hoverFindCallable(file!, location.line, location.utf16index, &function, &content)
    self.hoverFindIdentifier(file!, location.line, location.utf16index, &content, &requery)
    if content == nil,
      let tuple = self.tree!.metadata!.findKwargAt(file!, location.line, location.utf16index)
    {
      let kw = tuple.0
      let f = tuple.1
      var fun: Function?
      if let me = kw.parent!.parent as? MethodExpression {
        fun = me.method
      } else if let fe = kw.parent!.parent as? FunctionExpression {
        fun = fe.function
      }
      if let k = kw.key as? IdExpression {
        content = f.id() + "<" + k.id + ">"
        if fun != nil, let f = fun!.kwargs[k.id] {
          kwargTypes = f.types.map { $0.toString() }.joined(separator: "|")
        }
      }
    }
    if content != nil && requery {
      if function == nil {  // Kwarg docs
        let d = self.docs.find_docs(id: content!)
        content = (d ?? content!) + "\n\n*Types:*`" + (kwargTypes ?? "???") + "`"
      } else {
        let d = self.docs.find_docs(id: content!)
        if let mdocs = d {
          content = self.callHover(content: content, mdocs: mdocs, function: function)
        }
      }
    }
    req.reply(
      HoverResponse(
        contents: content == nil
          ? .markedStrings([])
          : .markupContent(MarkupContent(kind: .markdown, value: content ?? "")),
        range: nil
      )
    )
    Timing.INSTANCE.registerMeasurement(name: "hover", begin: begin, end: clock())
  }

  private func callHover(content: String?, mdocs: String, function: Function?) -> String {
    var str = "`" + content! + "`\n\n" + mdocs + "\n\n"
    for arg in function!.args {
      if let pa = arg as? PositionalArgument {
        str += "- "
        if pa.opt { str += "\\[" }
        str += "`" + pa.name + "`"
        str += " "
        str += pa.types.map { $0.toString() }.joined(separator: "|")
        if pa.varargs { str += "..." }
        if pa.opt { str += "\\]" }
        str += "\n"
      } else if let kw = arg as? Kwarg {
        str += "- "
        if kw.opt { str += "\\[" }
        str += "`" + kw.name + "`"
        str += ": "
        str += kw.types.map({ $0.toString() }).joined(separator: "|")
        if kw.opt { str += "\\]" }
        str += "\n"
      }
    }
    if !function!.returnTypes.isEmpty {
      str += "\n*Returns:* " + function!.returnTypes.map { $0.toString() }.joined(separator: "|")
    }
    return str
  }

  private func declaration(_ req: Request<DeclarationRequest>) {
    let beginDeclaration = clock()
    let location = req.params.position
    let file = req.params.textDocument.uri.fileURL?.path
    if let i = self.tree!.metadata!.findIdentifierAt(file!, location.line, location.utf16index),
      let t = self.tree!.findDeclaration(node: i)
    {
      let newFile = t.0
      let line = t.1[0]
      let column = t.1[1]
      let range = Range(LanguageServerProtocol.Position(line: Int(line), utf16index: Int(column)))
      Self.LOG.info("Found declaration")
      req.reply(.locations([.init(uri: DocumentURI(URL(fileURLWithPath: newFile)), range: range)]))
      let endDeclaration = clock()
      Timing.INSTANCE.registerMeasurement(
        name: "declaration",
        begin: Int(beginDeclaration),
        end: Int(endDeclaration)
      )
      return
    }

    if let sd = self.tree!.metadata!.findSubdirCallAt(file!, location.line, location.utf16index) {
      let path = Path(
        Path(file!).parent().description + Path.separator + sd.subdirname
          + "\(Path.separator)meson.build"
      ).description
      let range = Range(LanguageServerProtocol.Position(line: Int(0), utf16index: Int(0)))
      req.reply(.locations([.init(uri: DocumentURI(URL(fileURLWithPath: path)), range: range)]))
      let endDeclaration = clock()
      Timing.INSTANCE.registerMeasurement(
        name: "declaration",
        begin: Int(beginDeclaration),
        end: Int(endDeclaration)
      )
      return
    }
    Self.LOG.warning("Found no declaration")
    req.reply(.locations([]))
    let endDeclaration = clock()
    Timing.INSTANCE.registerMeasurement(
      name: "declaration",
      begin: Int(beginDeclaration),
      end: Int(endDeclaration)
    )
  }

  private func definition(_ req: Request<DefinitionRequest>) {
    let begin = clock()
    let location = req.params.position
    let file = req.params.textDocument.uri.fileURL?.path
    if let i = self.tree!.metadata!.findIdentifierAt(file!, location.line, location.utf16index),
      let t = self.tree!.findDeclaration(node: i)
    {
      let newFile = t.0
      let line = t.1[0]
      let column = t.1[1]
      let range = Range(LanguageServerProtocol.Position(line: Int(line), utf16index: Int(column)))
      Self.LOG.info("Found definition")
      req.reply(.locations([.init(uri: DocumentURI(URL(fileURLWithPath: newFile)), range: range)]))
      Timing.INSTANCE.registerMeasurement(name: "definition", begin: begin, end: clock())
      return
    }

    if let sd = self.tree!.metadata!.findSubdirCallAt(file!, location.line, location.utf16index) {
      let path = Path(
        Path(file!).parent().description + Path.separator + sd.subdirname
          + "\(Path.separator)meson.build"
      ).description
      let range = Range(LanguageServerProtocol.Position(line: Int(0), utf16index: Int(0)))
      req.reply(.locations([.init(uri: DocumentURI(URL(fileURLWithPath: path)), range: range)]))
      Timing.INSTANCE.registerMeasurement(name: "definition", begin: begin, end: clock())
      return
    }
    Self.LOG.warning("Found no definition")
    req.reply(.locations([]))
    Timing.INSTANCE.registerMeasurement(name: "definition", begin: begin, end: clock())
  }

  private func clearDiagnostics() {
    if self.tree != nil && self.tree!.metadata != nil {
      for k in self.tree!.metadata!.diagnostics.keys
      where self.tree!.metadata!.diagnostics[k] != nil {
        let arr: [Diagnostic] = []
        self.client.send(
          PublishDiagnosticsNotification(
            uri: DocumentURI(URL(fileURLWithPath: k)),
            diagnostics: arr
          )
        )
        self.tree!.metadata!.diagnostics.removeValue(forKey: k)
      }
    }
  }

  private func rebuildTree() {
    #if !os(Windows)
      let oldValue = self.lastAskedForRebuild.load(ordering: .acquiring) + 1
      self.lastAskedForRebuild.store(oldValue, ordering: .sequentiallyConsistent)
    #else
      let oldValue = self.lastAskedForRebuild + 1
      self.lastAskedForRebuild += 1
    #endif
    queue.async {
      let beginRebuilding = clock()
      self.clearDiagnostics()
      let endClearing = clock()
      Timing.INSTANCE.registerMeasurement(
        name: "clearingDiagnostics",
        begin: Int(beginRebuilding),
        end: Int(endClearing)
      )
      #if !os(Windows)
        var newValue = self.lastAskedForRebuild.load(ordering: .acquiring)
      #else
        var newValue = self.lastAskedForRebuild
      #endif
      if oldValue != newValue {
        Self.LOG.info(
          "Cancelling parsing - After clearing diagnostics (\(oldValue) vs \(newValue))"
        )
        return
      }
      let tmptree = MesonTree(
        file: self.path! + "/meson.build",
        ns: self.ns,
        dontCache: self.openFiles,
        cache: &self.astCache,
        memfiles: self.memfiles
      )
      let endParsingEntireTree = clock()
      Timing.INSTANCE.registerMeasurement(
        name: "parsingEntireTree",
        begin: Int(endClearing),
        end: Int(endParsingEntireTree)
      )
      #if !os(Windows)
        newValue = self.lastAskedForRebuild.load(ordering: .acquiring)
      #else
        newValue = self.lastAskedForRebuild
      #endif
      if oldValue != newValue {
        Self.LOG.info("Cancelling build - After building tree (\(oldValue) vs \(newValue))")
        return
      }
      tmptree.analyzeTypes(
        ns: self.ns,
        dontCache: self.openFiles,
        cache: &self.astCache,
        memfiles: self.memfiles
      )
      #if !os(Windows)
        newValue = self.lastAskedForRebuild.load(ordering: .acquiring)
      #else
        newValue = self.lastAskedForRebuild
      #endif
      if oldValue != newValue {
        Self.LOG.info("Cancelling build - After analyzing types (\(oldValue) vs \(newValue))")
        return
      }
      let endAnalyzingTypes = clock()
      Timing.INSTANCE.registerMeasurement(
        name: "analyzingTypes",
        begin: Int(endParsingEntireTree),
        end: Int(endAnalyzingTypes)
      )
      if tmptree.metadata == nil {
        let endRebuilding = clock()
        Timing.INSTANCE.registerMeasurement(
          name: "rebuildTree",
          begin: Int(beginRebuilding),
          end: Int(endRebuilding)
        )
        return
      }
      self.sendNewDiagnostics(tmptree)
      let endSendingDiagnostics = clock()
      Timing.INSTANCE.registerMeasurement(
        name: "sendingDiagnostics",
        begin: Int(endAnalyzingTypes),
        end: Int(endSendingDiagnostics)
      )
      Timing.INSTANCE.registerMeasurement(
        name: "rebuildTree",
        begin: Int(beginRebuilding),
        end: Int(endSendingDiagnostics)
      )
      #if !os(Windows)
        newValue = self.lastAskedForRebuild.load(ordering: .acquiring)
      #else
        newValue = self.lastAskedForRebuild
      #endif
      if oldValue != newValue {
        Self.LOG.info("Cancelling build - After sending diagnostics (\(oldValue) vs \(newValue))")
        if let md = tmptree.metadata {
          for k in md.diagnostics.keys where md.diagnostics[k] != nil {
            let arr: [Diagnostic] = []
            self.client.send(
              PublishDiagnosticsNotification(
                uri: DocumentURI(URL(fileURLWithPath: k)),
                diagnostics: arr
              )
            )
            md.diagnostics.removeValue(forKey: k)
          }
        }
        return
      }
      self.tree = tmptree
    }
  }

  private func sendNewDiagnostics(_ tmptree: MesonTree) {
    for k in tmptree.metadata!.diagnostics.keys where tmptree.metadata!.diagnostics[k] != nil {
      var arr: [Diagnostic] = []
      let diags = tmptree.metadata!.diagnostics[k]!
      Self.LOG.info("Publishing \(diags.count) diagnostics for \(k)")
      for diag in diags {
        if diag.severity == .error {
          Self.LOG.error("\(diag.message)")
        } else {
          Self.LOG.warning("\(diag.message)")
        }
        let s = LanguageServerProtocol.Position(
          line: Int(diag.startLine),
          utf16index: Int(diag.startColumn)
        )
        let e = LanguageServerProtocol.Position(
          line: Int(diag.endLine),
          utf16index: Int(diag.endColumn)
        )
        let sev: DiagnosticSeverity = diag.severity == .error ? .error : .warning
        arr.append(Diagnostic(range: s..<e, severity: sev, source: nil, message: diag.message))
      }
      self.client.send(
        PublishDiagnosticsNotification(uri: DocumentURI(URL(fileURLWithPath: k)), diagnostics: arr)
      )
    }
  }

  private func openDocument(_ note: Notification<DidOpenTextDocumentNotification>) {
    let file = note.params.textDocument.uri.fileURL?.path
    self.openFiles.insert(file!)
    self.astCache.removeValue(forKey: file!)
  }

  private func didSaveDocument(_ note: Notification<DidSaveTextDocumentNotification>) {
    let file = note.params.textDocument.uri.fileURL?.path
    // Either the saves were changed or dropped, so use the contents
    // of the file
    Self.LOG.info("[Save] Dropping \(file!) from memcache")
    self.memfiles.removeValue(forKey: file!)
    self.rebuildTree()
  }

  private func closeDocument(_ note: Notification<DidCloseTextDocumentNotification>) {
    let file = note.params.textDocument.uri.fileURL?.path
    // Either the saves were changed or dropped, so use the contents
    // of the file
    Self.LOG.info("[Close] Dropping \(file!) from memcache")
    self.openFiles.remove(file!)
    self.memfiles.removeValue(forKey: file!)
    self.rebuildTree()
  }

  private func changeDocument(_ note: Notification<DidChangeTextDocumentNotification>) {
    let file = note.params.textDocument.uri.fileURL?.path
    Self.LOG.info("[Change] Adding \(file!) to memcache")
    self.memfiles[file!] = note.params.contentChanges[0].text
    self.rebuildTree()
  }

  private func didCreateFiles(_ note: Notification<DidCreateFilesNotification>) {
    self.rebuildTree()
  }

  private func didDeleteFiles(_ note: Notification<DidDeleteFilesNotification>) {
    for f in note.params.files {
      let path = f.uri.fileURL!.path
      if self.memfiles[path] != nil { self.memfiles.removeValue(forKey: path) }
      if self.openFiles.contains(path) { self.openFiles.remove(path) }
      if self.astCache[path] != nil { self.astCache.removeValue(forKey: path) }
    }
    self.rebuildTree()
  }

  private func capabilities() -> ServerCapabilities {
    return ServerCapabilities(
      textDocumentSync: .options(
        TextDocumentSyncOptions(openClose: true, change: .full, save: .bool(true))
      ),
      hoverProvider: .bool(true),
      completionProvider: .some(
        CompletionOptions(resolveProvider: false, triggerCharacters: ["."])
      ),
      definitionProvider: .bool(true),
      documentHighlightProvider: .bool(true),
      documentSymbolProvider: .bool(true),
      workspaceSymbolProvider: .bool(true),
      documentFormattingProvider: .bool(true),
      declarationProvider: .bool(true),
      workspace: WorkspaceServerCapabilities(),
      inlayHintProvider: .bool(true)
    )
  }

  private func initialize(_ req: Request<InitializeRequest>) {
    let p = req.params
    if let clientInfo = p.clientInfo {
      Self.LOG.info("Connected with client \(clientInfo.name) \(clientInfo.version ?? "Unknown")")
    }
    if p.rootPath == nil { fatalError("Nothing else supported other than using rootPath") }
    self.path = p.rootPath
    self.rebuildTree()
    req.reply(InitializeResult(capabilities: self.capabilities()))
  }

  private func clientInitialized(_: Notification<InitializedNotification>) {
    // Nothing to do.
  }

  private func cancelRequest(_ notification: Notification<CancelRequestNotification>) {
    // No cancellation for anything supported (yet?)
  }

  private func shutdown(_ request: Request<ShutdownRequest>) {
    self.prepareForExit()
    #if os(Linux)
      self.server.stop()
    #endif
    request.reply(VoidResponse())
  }

  private func exit(_ notification: Notification<ExitNotification>) {
    self.prepareForExit()
    self.onExit()
  }

  private func generateHTML() -> String {
    let header = """
      	<!DOCTYPE html>
      	<html>
      	<head>
      	<meta http-equiv="refresh" content="5" />
      	<style>
      	table {
      		font-family: arial, sans-serif;
      		border-collapse: collapse;
      		width: 100%;
      	}

      	td, th {
      		border: 1px solid #dddddd;
      		text-align: left;
      		padding: 8px;
      	}

      	tr:nth-child(even) {
      		background-color: #dddddd;
      	}
      	</style>
      	</head>
      	<body>

      	<h2>Timing information</h2>

      	<table>
      		<tr>
      			<th>Identifier</th>
      			<th>Hits</th>
      			<th>Min</th>
      			<th>Max</th>
      			<th>Median</th>
      			<th>Average</th>
      			<th>Standard deviation</th>
      			<th>Sum</th>
      		</tr>
      """
    var str = ""
    for t in Timing.INSTANCE.timings() {
      let rounding = 2
      str.append(
        "<tr>" + "<td>\(t.name)</td>" + "<td>\(t.hits())</td>"
          + "<td>\(t.min().round(to: rounding))</td>" + "<td>\(t.max().round(to: rounding))</td>"
          + "<td>\(t.median().round(to: rounding))</td>"
          + "<td>\(t.average().round(to: rounding))</td>"
          + "<td>\(t.stddev().round(to: rounding))</td>"
          + "<td>\(t.sum().round(to: rounding))</td></tr>"
      )
    }
    let footer = """
      	</table>

      	</body>
      	</html>
      """
    return header + str + footer
  }
}

extension Double {
  func round(to places: Int) -> Double {
    let base = 10
    let divisor = pow(Double(base), Double(places))
    return (self * divisor).rounded() / divisor
  }
}

extension String {
  subscript(offset: Int) -> Character { return self[index(startIndex, offsetBy: offset)] }
  subscript(_ range: CountableRange<Int>) -> String {
    let start = index(startIndex, offsetBy: max(0, range.lowerBound))
    let end = index(
      start,
      offsetBy: min(self.count - range.lowerBound, range.upperBound - range.lowerBound)
    )
    return String(self[start..<end])
  }

  subscript(_ range: CountablePartialRangeFrom<Int>) -> String {
    let start = index(startIndex, offsetBy: max(0, range.lowerBound))
    return String(self[start...])
  }
}
