
import Foundation
import zlib

enum FileInfo {

    // MARK: - Public entry point

    static func getInfoMinimum(url: URL, isLimit: Bool = true, timeLimitSec: Int? = nil, notDetectXMP: Bool = true, notDetectEPSCompatibleVer: Bool? = nil) -> FileClass? {
        var resolved = url

        guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }

        if let bookmarkURL = resolveAlias(url: resolved) {
            resolved = bookmarkURL
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
        guard !isDir.boolValue, !resolved.hasDirectoryPath else { return nil }

        let prefs = Preferences.shared
        let timeLimit = Double(timeLimitSec ?? prefs.timeLimit)
        let notDetectEPSCompatibleVer = notDetectEPSCompatibleVer ?? prefs.isNotDetectEPSCompatibleVer

        let startTotal = Date()
        let fc = FileClass()
        fc.file = resolved

        // 1. Finder 拡張属性
        let (fileType, creator) = getFinderInfo(url: resolved)
        fc.finderInfo_FileType = fileType
        fc.finderInfo_Creator  = creator

        // PDF構造かどうかを早期判定し、xref を一度だけ解析して以降で共有する
        let pdfXref: (root: Int, offsets: [Int: UInt64])? = {
            guard isPDFBased(url: resolved),
                  let fh = try? FileHandle(forReadingFrom: resolved) else { return nil }
            defer { try? fh.close() }
            return parsePDFXref(fh: fh)
        }()

        let ext = resolved.pathExtension.lowercased()

        // 2. XMP CreatorTool（notDetectXMP = true のときはスキップ）
        let xmpStart = Date()
        if !notDetectXMP {
            if let xref = pdfXref {
                if let fh = try? FileHandle(forReadingFrom: resolved) {
                    defer { try? fh.close() }
                    fc.xmp_CreatorTool = getCreatorToolViaXref(root: xref.root,
                                                                offsets: xref.offsets, fh: fh)
                }
            } else if ext != "ai" && ext != "ait" {
                fc.xmp_CreatorTool = getCreatorTool(url: resolved)
            }
        }
        fc.time_XMP_CreatorTool = microsecondsString(from: xmpStart)

        // 3. ファイル種別判定（拡張子非依存・コンテンツベース）
        fc.kind = getFileKind(fc: fc, url: resolved, pdfXref: pdfXref)

        // 4. XMP CreatorTool による補完（非PDF構造ファイルで Creator コメントが欠落しているケース）
        if !fc.isIllustratorFile && pdfXref == nil && fc.xmp_CreatorTool.contains("Illustrator") {
            if fc.kind == "Ai" || fc.kind == "EPS" {
                fc.isIllustratorFile = true
            }
        }

        // 5. バージョンコメントスキャン
        if fc.isIllustratorFile {
            if let xref = pdfXref {
                scanVersionCommentsFromPDF(xref: xref, url: resolved, fc: fc)
            } else {
                scanVersionComments(url: resolved, fc: fc, isLimit: isLimit,
                                    timeLimit: timeLimit,
                                    notDetectEPSCompatibleVer: notDetectEPSCompatibleVer,
                                    startTotal: startTotal)
            }
            determineVersion(fc: fc)
        } else {
            fc.hasCreator2 = false
        }

        // 6. アプリ名
        if fc.isIllustratorFile {
            fc.appName = "Illustrator"
        } else if isPhotoshopFile(url: resolved, kind: fc.kind) || fc.xmp_CreatorTool.contains("Photoshop") {
            fc.appName = "Photoshop"
        }

        fc.time_TotalSeconds = String(format: "%.3f", Date().timeIntervalSince(startTotal))
        return fc
    }

    // MARK: - VersionName

    static func versionName(_ ver: String) -> String {
        let parts = ver.components(separatedBy: ".")
        let major = Int(parts.first ?? "") ?? 0
        // minor 部に locale サフィックス（例: "5J"）が付いている場合は数値部と接尾辞を分離する
        let (minor, minorSuffix): (Int, String) = {
            guard parts.count > 1 else { return (0, "") }
            let raw = parts[1]
            let digits = raw.prefix(while: { $0.isNumber })
            let suffix = raw[digits.endIndex...]
            return (Int(digits) ?? 0, String(suffix))
        }()

        switch major {
        case 1...4:  return parts[0]
        case 5:      return minorSuffix.isEmpty ? (minor > 0 ? "5.\(minor)" : "5") : "5"
        case 6...10: return parts[0]
        case 11:     return "CS"
        case 12:     return "CS2"
        case 13:     return "CS3"
        case 14:     return "CS4"
        case 15:     return minor > 0 ? "CS5.\(minor)" : "CS5"
        case 16:     return "CS6"
        case 17:     return "CC"
        case 18:     return "CC 2014"
        case 19:     return "CC 2015"
        case 20:     return "CC 2015.3"
        case 21:     return "CC 2017"
        case 22:     return "CC 2018"
        case 23:     return "CC 2019"
        default:     return major > 23 ? "\(major + 1996)" : ver
        }
    }

    // MARK: - Utilities

    static func regexMatch(in string: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let matchRange = Range(match.range, in: string) else { return "" }
        return String(string[matchRange])
    }

    // MARK: - Finder Info

    private static func getFinderInfo(url: URL) -> (fileType: String, creator: String) {
        let path = url.path
        var buf = [UInt8](repeating: 0, count: 32)
        let result = getxattr(path, "com.apple.FinderInfo", &buf, 32, 0, 0)
        guard result >= 8 else { return ("", "") }
        let fileType = String(bytes: buf[0..<4], encoding: .macOSRoman) ?? ""
        let creator  = String(bytes: buf[4..<8], encoding: .macOSRoman) ?? ""
        return (fileType, creator)
    }

    // MARK: - XMP CreatorTool

    private static func getCreatorTool(url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int else { return "" }

        for limit in [1_000_000, 10_000_000, 50_000_000] {
            if fileSize <= limit || limit == 50_000_000 {
                if let s = creatorToolFromBinary(url: url, byteCount: min(limit, fileSize)) {
                    return s
                }
                break
            }
        }
        return ""
    }

    private static func creatorToolFromBinary(url: URL, byteCount: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        let data = fh.readData(ofLength: byteCount)
        try? fh.close()
        guard let s = String(data: data, encoding: .isoLatin1)
                   ?? String(data: data, encoding: .utf8) else { return nil }
        let result = extractCreatorToolFromXMP(s)
        return result.isEmpty ? nil : result
    }

    private static func extractCreatorToolFromXMP(_ s: String) -> String {
        if let start = s.range(of: "<xmp:CreatorTool>") {
            let tail = String(s[start.upperBound...].prefix(200))
            if let end = tail.range(of: "<") {
                return String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        if let start = s.range(of: #"xmp:CreatorTool=""#) {
            let tail = String(s[start.upperBound...].prefix(200))
            if let end = tail.range(of: "\"") {
                return String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    // MARK: - File Kind

    /// ファイル種別を判定する（拡張子に依存しない・コンテンツベース）
    ///
    /// 判定順：
    /// - A. PDF 構造（先頭 `%PDF-`）
    ///     1. `/AIPDFPrivateData` あり → `kind="PDF"`, isIllustratorFile=true（Illustrator編集機能保持PDF）
    ///     2. AIMetaData オブジェクトあり → `kind="Ai"`, isIllustratorFile=true（通常の.ai形式）
    ///     3. それ以外 → `kind="PDF"`（通常PDF）
    /// - B. PostScript セクション（生PSヘッダ or バイナリEPSラッパ後のPS）
    ///     - 1行目に `EPSF-` を含む → `kind="EPS"`、`%%Creator:` で Illustrator/Photoshop を判定
    ///     - 含まない（純PSの旧.ai） → Illustrator マーカーがあれば `kind="Ai"`, isIllustratorFile=true
    /// - C. PSD ネイティブ（先頭4B = `8BPS`） → `kind="PSD"`
    /// - D. それ以外 → `kind=""`
    ///
    /// Finder Creator/FileType（ART5/8BIM）は最初に短絡させる（クラシックMac互換）。
    private static func getFileKind(fc: FileClass, url: URL, pdfXref: (root: Int, offsets: [Int: UInt64])?) -> String {
        // Finder 情報での早期判定（クラシックMac互換）
        if fc.finderInfo_Creator == "ART5" {
            if ["TEXT", "PDF ", "AITm"].contains(fc.finderInfo_FileType) {
                fc.isIllustratorFile = true
                if fc.finderInfo_FileType == "AITm" { fc.isTemplate = true }
                return epsHeaderCheck(url: url) ? "EPS" : "Ai"
            } else if ["EPSF", "EPSP"].contains(fc.finderInfo_FileType) {
                fc.isIllustratorFile = true
                return "EPS"
            }
        } else if fc.finderInfo_Creator == "8BIM" && fc.finderInfo_FileType == "EPSF" {
            fc.isIllustratorFile = false
            return "EPS"
        }

        // A. PDF 構造
        if let xref = pdfXref {
            // A-1. /AIPDFPrivateData → Illustrator編集機能保持PDF
            if isAIPDFFormat(url: url) {
                fc.isIllustratorFile = true
                return "PDF"
            }
            // A-2. AIMetaData → 通常の.ai形式（PDF）
            if let fh = try? FileHandle(forReadingFrom: url) {
                defer { try? fh.close() }
                if traverseToAIMetaDataObj(root: xref.root, offsets: xref.offsets, fh: fh) != nil {
                    fc.isIllustratorFile = true
                    // 先頭2KBのdc:formatで本物の.aitか判定（バイト列検索のみ・XMLパースなし）
                    fc.isTemplate = isIllustratorTemplateFormat(url: url)
                    return "Ai"
                }
            }
            // A-2.5. xref を辿れない場合の前方探索フォールバック。
            //   ページ辞書が巨大で /PieceInfo が pdfObjStr の読み取り上限を超える、
            //   または xref ストリーム形式等で traverse が失敗しても、
            //   ファイル中に /AIMetaData があれば通常の .ai と判定する（WebApp AFVer と同挙動）。
            if fileContainsMarker(url: url, marker: "/AIMetaData") {
                fc.isIllustratorFile = true
                fc.isTemplate = isIllustratorTemplateFormat(url: url)
                return "Ai"
            }
            // A-3. それ以外 → 通常PDF
            return "PDF"
        }

        // B. PostScript セクション
        if let ps = epsReadPSHeader(url: url, length: 16384) {
            let firstLine = ps.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
            if firstLine.contains("%!PS-Adobe-") {
                let isIllustratorPS = ps.contains("%%AI8_CreatorVersion:")
                    || ps.contains("%%Creator: Adobe Illustrator")
                    || ps.contains("%%Creator: (Adobe Illustrator")
                if firstLine.contains("EPSF-") {
                    fc.isIllustratorFile = isIllustratorPS
                    return "EPS"
                }
                if isIllustratorPS {
                    // 旧形式.ai（純PostScript）
                    fc.isIllustratorFile = true
                    return "Ai"
                }
                // PS だが Illustrator/Photoshop でもない → 不明にフォールスルー
            }
        }

        // C. PSD ネイティブ（8BPS マジック）
        if let fh = try? FileHandle(forReadingFrom: url) {
            let magic = fh.readData(ofLength: 4)
            try? fh.close()
            if magic.starts(with: Data("8BPS".utf8)) {
                return "PSD"
            }
        }

        // D. 不明
        return ""
    }

    private static func epsHeaderCheck(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        let header = fh.readData(ofLength: 512)
        try? fh.close()
        return (String(data: header, encoding: .isoLatin1) ?? "").contains("EPSF-")
    }

    private static func epsReadPSHeader(url: URL, length: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let magic = fh.readData(ofLength: 4)
        if magic == Data([0xC5, 0xD0, 0xD3, 0xC6]) {
            let offsetData = fh.readData(ofLength: 4)
            guard offsetData.count == 4 else { return nil }
            let psOffset = UInt64(offsetData[0])
                         | UInt64(offsetData[1]) << 8
                         | UInt64(offsetData[2]) << 16
                         | UInt64(offsetData[3]) << 24
            try? fh.seek(toOffset: psOffset)
        } else {
            try? fh.seek(toOffset: 0)
        }
        return String(data: fh.readData(ofLength: length), encoding: .isoLatin1)
    }

    private static func epsIsIllustrator(url: URL) -> Bool {
        guard let ps = epsReadPSHeader(url: url, length: 16384) else { return false }
        return ps.contains("%%AI8_CreatorVersion:")
            || ps.contains("%%Creator: Adobe Illustrator")
            || ps.contains("%%Creator: (Adobe Illustrator")
    }

    private static func epsIsPhotoshop(url: URL) -> Bool {
        guard let ps = epsReadPSHeader(url: url, length: 16384) else { return false }
        return ps.contains("%%Creator: Adobe Photoshop")
    }

    private static func isPhotoshopFile(url: URL, kind: String) -> Bool {
        if kind == "PSD" { return true }
        if kind == "EPS" { return epsIsPhotoshop(url: url) }
        return false
    }

    // MARK: - PDF構造ファイル判定

    private static func isPDFBased(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        let header = fh.readData(ofLength: 5)
        try? fh.close()
        return header.starts(with: Data("%PDF-".utf8))
    }

    /// Illustrator編集機能保持PDF判定（.ai偽装検出用）
    /// 通常の .ai は /AIPrivateData、Illustrator編集機能保持PDFは /AIPDFPrivateData を持つ
    private static func isAIPDFFormat(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 65536)
        return data.range(of: Data("/AIPDFPrivateData".utf8)) != nil
    }

    /// ファイル全体をチャンク読みして指定マーカーの有無を返す（前方探索フォールバック用）
    /// 全体を一度にメモリへ載せず、チャンク境界での取りこぼしを overlap で防ぐ。
    private static func fileContainsMarker(url: URL, marker: String) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let needle = Data(marker.utf8)
        guard needle.count > 0 else { return false }
        let overlap = needle.count - 1
        let chunkSize = 1 << 20  // 1MB
        var carry = Data()
        while true {
            let chunk = fh.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            var buf = carry
            buf.append(chunk)
            if buf.range(of: needle) != nil { return true }
            // 末尾 overlap バイトを次回チャンクへ持ち越し、境界をまたぐマーカーを検出
            carry = buf.count > overlap ? buf.suffix(overlap) : buf
            if chunk.count < chunkSize { break }
        }
        return false
    }

    /// 本物のIllustratorテンプレート（.ait）判定
    /// 先頭2KBのdc:formatを文字列検索するだけ（XMLパースなし）
    /// 本物の.ait: dc:format = application/vnd.adobe.illustrator
    /// .aiを改名:  dc:format = application/pdf
    private static func isIllustratorTemplateFormat(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 2048)
        let marker = Data("application/vnd.adobe.illustrator".utf8)
        return data.range(of: marker) != nil
    }

    // MARK: - PDF AIMetaData スキャン

    private static func scanVersionCommentsFromPDF(
        xref: (root: Int, offsets: [Int: UInt64]), url: URL, fc: FileClass
    ) {
        let streamData: Data
        if let d = aiMetaDataStream(xref: xref, url: url) {
            streamData = d
        } else if let d = aiMetaDataStreamForward(url: url) {
            streamData = d
        } else {
            return
        }

        if fc.kind != "EPS" && fc.kind != "PDF" { fc.kind = "Ai" }
        var t = Date()
        let lines = streamData.split(omittingEmptySubsequences: true) { $0 == 0x0D || $0 == 0x0A }
        for line in lines {
            processLineData(line, fc: fc, t: &t)
            if !fc.creator1.isEmpty && !fc.ai8_CreatorVersion.isEmpty {
                fc.hasCreator2 = false; return
            }
        }
    }

    private static func aiMetaDataStream(
        xref: (root: Int, offsets: [Int: UInt64]), url: URL
    ) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let metaNum = traverseToAIMetaDataObj(root: xref.root,
                                                    offsets: xref.offsets, fh: fh) else { return nil }
        return readPDFObjStream(num: metaNum, offsets: xref.offsets, fh: fh)
    }

    private static func getCreatorToolViaXref(
        root: Int, offsets: [Int: UInt64], fh: FileHandle
    ) -> String {
        guard let catStr  = pdfObjStr(num: root, offsets: offsets, fh: fh),
              let metaN   = pdfObjRef("Metadata", in: catStr),
              let metaOff = offsets[metaN] else { return "" }

        try? fh.seek(toOffset: metaOff)
        let headerData = fh.readData(ofLength: 512)
        let lenKey = Data("/Length ".utf8)
        guard let lkr = headerData.range(of: lenKey) else { return "" }
        let afterLen = headerData[lkr.upperBound...]
        var lenEnd = afterLen.startIndex
        while lenEnd < afterLen.endIndex
            && afterLen[lenEnd] >= UInt8(ascii: "0")
            && afterLen[lenEnd] <= UInt8(ascii: "9") { lenEnd += 1 }
        guard let lenStr = String(data: afterLen[..<lenEnd], encoding: .ascii),
              let totalLen = Int(lenStr), totalLen > 0 else { return "" }

        let streamKey = Data("stream".utf8)
        guard let skr = headerData.range(of: streamKey) else { return "" }
        var bodyIdx = skr.upperBound
        if bodyIdx < headerData.endIndex && headerData[bodyIdx] == 0x0D { bodyIdx += 1 }
        if bodyIdx < headerData.endIndex && headerData[bodyIdx] == 0x0A { bodyIdx += 1 }

        let bodyFileOffset = metaOff + UInt64(bodyIdx - headerData.startIndex)
        let readLen = min(totalLen, chunkSize)
        try? fh.seek(toOffset: bodyFileOffset)
        let xmpData = fh.readData(ofLength: readLen)

        guard let s = String(data: xmpData, encoding: .utf8)
                   ?? String(data: xmpData, encoding: .isoLatin1) else { return "" }
        return extractCreatorToolFromXMP(s)
    }

    private static func parsePDFXref(fh: FileHandle) -> (root: Int, offsets: [Int: UInt64])? {
        guard let fileSize = try? fh.seekToEnd(), fileSize > 0 else { return nil }
        try? fh.seek(toOffset: fileSize - min(1024, fileSize))
        guard let tail = String(data: fh.readData(ofLength: 1024), encoding: .isoLatin1) else { return nil }
        var xrefOff: UInt64?
        for line in tail.components(separatedBy: .newlines).reversed() {
            if let v = UInt64(line.trimmingCharacters(in: .whitespacesAndNewlines)) { xrefOff = v; break }
        }
        guard let startOff = xrefOff else { return nil }

        var offsets = [Int: UInt64]()
        var root: Int?
        var queue = [startOff]
        var seen  = Set<UInt64>()

        while !queue.isEmpty {
            let off = queue.removeFirst()
            guard !seen.contains(off) else { continue }
            seen.insert(off)

            // xref テーブルが 32KB を超える大容量ファイルに対応するため、
            // "trailer" が見つかるまで 32KB ずつ読み足す
            try? fh.seek(toOffset: off)
            var xrefRaw = Data()
            let xrefChunk = 32768
            var trailerFound = false
            while !trailerFound {
                let chunk = fh.readData(ofLength: xrefChunk)
                if chunk.isEmpty { break }
                xrefRaw.append(chunk)
                if xrefRaw.range(of: Data("trailer".utf8)) != nil { trailerFound = true }
                if chunk.count < xrefChunk { break }
            }
            guard let s = String(data: xrefRaw, encoding: .isoLatin1),
                  s.hasPrefix("xref") else { continue }

            let sNorm = s.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
            var iter = sNorm.components(separatedBy: "\n").makeIterator()
            _ = iter.next()
            outer: while let line = iter.next() {
                let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if l.hasPrefix("trailer") { break }
                let parts = l.split(separator: " ")
                guard parts.count == 2,
                      let secStart = Int(parts[0]), let secCount = Int(parts[1]) else { continue }
                var objID = secStart
                for _ in 0..<secCount {
                    guard let entry = iter.next() else { break outer }
                    let ep = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                    if ep.count >= 3, ep[2] == "n", let fileOff = UInt64(ep[0]) {
                        offsets[objID] = fileOff
                    }
                    objID += 1
                }
            }

            if let tRange = s.range(of: "trailer") {
                let ts = String(s[tRange.upperBound...])
                if root == nil { root = pdfObjRef("Root", in: ts) }
                if let prev = pdfIntVal("Prev", in: ts) { queue.append(UInt64(prev)) }
            }
        }

        guard let r = root else { return nil }
        return (r, offsets)
    }

    private static func traverseToAIMetaDataObj(root: Int, offsets: [Int: UInt64], fh: FileHandle) -> Int? {
        guard let catStr   = pdfObjStr(num: root,       offsets: offsets, fh: fh),
              let pagesN   = pdfObjRef("Pages",          in: catStr),
              let pagesStr = pdfObjStr(num: pagesN,      offsets: offsets, fh: fh),
              let pageN    = pdfFirstKid(in: pagesStr),
              let pageStr  = pdfObjStr(num: pageN,       offsets: offsets, fh: fh),
              let illusN   = pdfObjRef("Illustrator",    in: pageStr),
              let illusStr = pdfObjStr(num: illusN,      offsets: offsets, fh: fh),
              let privN    = pdfObjRef("Private",        in: illusStr),
              let privStr  = pdfObjStr(num: privN,       offsets: offsets, fh: fh),
              let metaN    = pdfObjRef("AIMetaData",     in: privStr) else { return nil }
        return metaN
    }

    private static func pdfObjStr(num: Int, offsets: [Int: UInt64], fh: FileHandle) -> String? {
        guard let offset = offsets[num] else { return nil }
        try? fh.seek(toOffset: offset)
        guard let s = String(data: fh.readData(ofLength: 4096), encoding: .isoLatin1),
              s.hasPrefix("\(num) 0 obj") else { return nil }
        return s
    }

    private static func readPDFObjStream(num: Int, offsets: [Int: UInt64], fh: FileHandle) -> Data? {
        guard let offset = offsets[num] else { return nil }
        try? fh.seek(toOffset: offset)
        let headerData = fh.readData(ofLength: 8192)

        let lenKey = Data("/Length ".utf8)
        guard let lkr = headerData.range(of: lenKey) else { return nil }
        let afterLen = headerData[lkr.upperBound...]
        var lenEnd = afterLen.startIndex
        while lenEnd < afterLen.endIndex
            && afterLen[lenEnd] >= UInt8(ascii: "0")
            && afterLen[lenEnd] <= UInt8(ascii: "9") { lenEnd += 1 }
        guard let lenStr = String(data: afterLen[..<lenEnd], encoding: .ascii),
              let streamLen = Int(lenStr), streamLen > 0 else { return nil }

        let streamKey = Data("stream".utf8)
        guard let skr = headerData.range(of: streamKey) else { return nil }
        var bodyIdx = skr.upperBound
        if bodyIdx < headerData.endIndex && headerData[bodyIdx] == 0x0D { bodyIdx += 1 }
        if bodyIdx < headerData.endIndex && headerData[bodyIdx] == 0x0A { bodyIdx += 1 }

        let hasFilter = headerData[headerData.startIndex..<skr.lowerBound]
            .range(of: Data("/Filter".utf8)) != nil

        let bodyFileOffset = offset + UInt64(bodyIdx - headerData.startIndex)
        try? fh.seek(toOffset: bodyFileOffset)
        let raw = fh.readData(ofLength: streamLen)
        guard raw.count == streamLen else { return nil }

        return hasFilter ? zlibInflate(raw) : raw
    }

    // MARK: PDF パースヘルパー

    private static func pdfObjRef(_ key: String, in s: String) -> Int? {
        guard let re = try? NSRegularExpression(
                pattern: "/" + NSRegularExpression.escapedPattern(for: key) + #"\s+(\d+)\s+0\s+R"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    private static func pdfFirstKid(in s: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: #"/Kids\s*\[\s*(\d+)\s+0\s+R"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    private static func pdfIntVal(_ key: String, in s: String) -> Int? {
        guard let re = try? NSRegularExpression(
                pattern: "/" + NSRegularExpression.escapedPattern(for: key) + #"\s+(\d+)"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    // MARK: フォールバック（前方スキャン）

    private static func aiMetaDataStreamForward(url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let aiMetaKey = Data("/AIMetaData ".utf8)
        guard let keyRange = data.range(of: aiMetaKey) else { return nil }
        let after = data[keyRange.upperBound...]
        guard let spaceIdx = after.firstIndex(where: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: ">") }) else { return nil }
        guard let numStr = String(data: after[after.startIndex..<spaceIdx], encoding: .ascii),
              let objNum = Int(numStr) else { return nil }

        let objMarker = Data("\(objNum) 0 obj".utf8)
        guard let objRange = data.range(of: objMarker) else { return nil }
        let objHead = data[objRange.upperBound...]

        guard let lkr = objHead.range(of: Data("/Length ".utf8)) else { return nil }
        let la = objHead[lkr.upperBound...]
        guard let le = la.firstIndex(where: { $0 < UInt8(ascii: "0") || $0 > UInt8(ascii: "9") }),
              let lenStr = String(data: la[..<le], encoding: .ascii),
              let streamLen = Int(lenStr) else { return nil }

        guard let skr = objHead.range(of: Data("stream".utf8)) else { return nil }
        var ss = skr.upperBound
        if ss < objHead.endIndex && objHead[ss] == 0x0D { ss += 1 }
        if ss < objHead.endIndex && objHead[ss] == 0x0A { ss += 1 }
        guard ss + streamLen <= objHead.endIndex else { return nil }
        let raw = Data(objHead[ss..<(ss + streamLen)])

        let hasFilter = objHead[..<skr.lowerBound].range(of: Data("/Filter".utf8)) != nil
        return hasFilter ? zlibInflate(raw) : raw
    }

    // MARK: - zlib展開

    private static func zlibInflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        var result = Data()
        var stream = z_stream()
        var ret = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard ret == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let bufSize = 65536
        var buf = [UInt8](repeating: 0, count: bufSize)
        data.withUnsafeBytes { src in
            stream.next_in  = UnsafeMutablePointer(mutating: src.baseAddress!.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)
            repeat {
                buf.withUnsafeMutableBytes { dst in
                    stream.next_out  = dst.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(bufSize)
                }
                ret = inflate(&stream, Z_NO_FLUSH)
                let produced = bufSize - Int(stream.avail_out)
                if produced > 0 { result.append(contentsOf: buf[0..<produced]) }
            } while ret == Z_OK
        }
        return (ret == Z_STREAM_END || ret == Z_OK) ? result : nil
    }

    // MARK: - バージョンコメントスキャン（FileHandle + seek + %%BeginData スキップ）

    private static let chunkSize = 256 * 1024

    private static let markerCreator:   [UInt8] = Array("%%Creator: ".utf8)
    private static let markerAI8:       [UInt8] = Array("%%AI8_CreatorVersion: ".utf8)
    private static let markerBeginData: [UInt8] = Array("%%BeginData:".utf8)
    private static let markerEndData:   [UInt8] = Array("%%EndData".utf8)

    private static func scanVersionComments(url: URL, fc: FileClass, isLimit: Bool,
                                            timeLimit: Double, notDetectEPSCompatibleVer: Bool,
                                            startTotal: Date) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }

        var pending = Data()
        var pendingFileStart: UInt64 = 0
        var totalRead: UInt64 = 0
        var t = Date()

        mainLoop: while true {
            if isLimit && Date().timeIntervalSince(startTotal) > timeLimit {
                fc.isTimeOut = true; break
            }
            if fc.kind == "EPS" && !fc.creator1.isEmpty && !fc.ai8_CreatorVersion.isEmpty
                && notDetectEPSCompatibleVer { break }

            if pending.isEmpty {
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                pending = chunk
                pendingFileStart = totalRead
                totalRead += UInt64(chunk.count)
            }

            guard let nlRel = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    processLinePending(&pending, fc: fc, t: &t)
                    break
                }
                pending.append(chunk)
                totalRead += UInt64(chunk.count)
                if pending.count > 4 * 1024 * 1024 {
                    pending.removeAll()
                    pendingFileStart = totalRead
                }
                continue
            }

            let lineEnd = nlRel
            let lineLen = lineEnd - pending.startIndex

            var afterNl = pending.index(after: lineEnd)
            if pending[lineEnd] == 0x0D, afterNl < pending.endIndex, pending[afterNl] == 0x0A {
                afterNl = pending.index(after: afterNl)
            }
            let afterNlFileOffset = pendingFileStart + UInt64(afterNl - pending.startIndex)

            if lineLen < 2 || pending[pending.startIndex] != UInt8(ascii: "%")
                            || pending[pending.index(after: pending.startIndex)] != UInt8(ascii: "%") {
                pending = pending[afterNl...]
                pendingFileStart = afterNlFileOffset
                continue
            }

            if matchesPending(&pending, marker: markerBeginData, lineLen: lineLen) {
                let skipBytes = parseBeginDataByteCount(&pending, markerLen: markerBeginData.count, lineEnd: lineEnd)
                if skipBytes > 0 {
                    let seekTo = afterNlFileOffset + UInt64(skipBytes)
                    try? fh.seek(toOffset: seekTo)
                    totalRead = seekTo
                    pending.removeAll()
                    pendingFileStart = seekTo
                    let endChunk = fh.readData(ofLength: min(chunkSize, 4096))
                    if !endChunk.isEmpty {
                        totalRead += UInt64(endChunk.count)
                        pending = endChunk
                        if let edNl = findMarkerLine(in: pending, marker: markerEndData) {
                            var nextLine = pending.index(after: edNl)
                            if pending[edNl] == 0x0D, nextLine < pending.endIndex, pending[nextLine] == 0x0A {
                                nextLine = pending.index(after: nextLine)
                            }
                            pendingFileStart = seekTo + UInt64(nextLine - pending.startIndex)
                            pending = pending[nextLine...]
                        } else {
                            pendingFileStart = totalRead
                            pending.removeAll()
                        }
                    }
                    continue
                }
            }

            let lineSlice = pending[..<lineEnd]
            processLineData(lineSlice, fc: fc, t: &t)

            if fc.kind == "Ai" && !fc.creator1.isEmpty && !fc.ai8_CreatorVersion.isEmpty {
                fc.hasCreator2 = false; break mainLoop
            }
            if fc.kind == "EPS" && !fc.creator1.isEmpty && !fc.creator2.isEmpty { break mainLoop }
            if fc.kind == "EPS" && !fc.creator1.isEmpty && !fc.hasCreator2 { break mainLoop }

            pending = pending[afterNl...]
            pendingFileStart = afterNlFileOffset
        }
    }

    private static func matchesPending(_ pending: inout Data, marker: [UInt8], lineLen: Int) -> Bool {
        guard lineLen >= marker.count else { return false }
        for (i, b) in marker.enumerated() {
            if pending[pending.startIndex + i] != b { return false }
        }
        return true
    }

    private static func parseBeginDataByteCount(_ pending: inout Data, markerLen: Int, lineEnd: Data.Index) -> Int {
        var i = pending.startIndex + markerLen
        while i < lineEnd && pending[i] == UInt8(ascii: " ") { i += 1 }
        var n = 0; var found = false
        while i < lineEnd {
            let b = pending[i]
            if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") {
                n = n * 10 + Int(b - UInt8(ascii: "0")); found = true
            } else { break }
            i += 1
        }
        return found ? n : 0
    }

    private static func findMarkerLine(in data: Data, marker: [UInt8]) -> Data.Index? {
        var i = data.startIndex
        while i < data.endIndex {
            if i + marker.count <= data.endIndex {
                var match = true
                for (k, b) in marker.enumerated() {
                    if data[i + k] != b { match = false; break }
                }
                if match {
                    var j = i
                    while j < data.endIndex && data[j] != 0x0A && data[j] != 0x0D { j += 1 }
                    return j < data.endIndex ? j : nil
                }
            }
            while i < data.endIndex && data[i] != 0x0A && data[i] != 0x0D { i += 1 }
            if i < data.endIndex {
                let nl = i; i = data.index(after: nl)
                if data[nl] == 0x0D, i < data.endIndex, data[i] == 0x0A { i = data.index(after: i) }
            }
        }
        return nil
    }

    private static func processLineData(_ lineSlice: Data.SubSequence, fc: FileClass, t: inout Date) {
        let lineLen = lineSlice.count
        guard lineLen > 2 else { return }

        if fc.creator1.isEmpty && lineLen > markerCreator.count
            && lineSlice.starts(with: markerCreator) {
            fc.creator1 = extractString(from: lineSlice, offset: markerCreator.count)
            fc.time_Creator1 = microsecondsString(from: t); t = Date()

        } else if fc.ai8_CreatorVersion.isEmpty && lineLen > markerAI8.count
            && lineSlice.starts(with: markerAI8) {
            fc.ai8_CreatorVersion = extractString(from: lineSlice, offset: markerAI8.count)
            fc.time_AI8_CreatorVersion = microsecondsString(from: t); t = Date()

            if fc.kind == "EPS" && !fc.creator1.isEmpty {
                if let ver = illustratorMajorVersion(from: fc.creator1), ver < 9 {
                    fc.hasCreator2 = false
                }
            }

        } else if fc.kind == "EPS" && !fc.creator1.isEmpty && fc.creator2.isEmpty
            && lineLen > markerCreator.count
            && lineSlice.starts(with: markerCreator) {
            fc.creator2 = extractString(from: lineSlice, offset: markerCreator.count)
            fc.time_Creator2 = microsecondsString(from: t)
            fc.hasCreator2 = true
        }
    }

    private static func processLinePending(_ pending: inout Data, fc: FileClass, t: inout Date) {
        processLineData(pending[...], fc: fc, t: &t)
    }

    private static func extractString(from slice: Data.SubSequence, offset: Int) -> String {
        let sub = slice.dropFirst(offset)
        var s = String(data: sub, encoding: .utf8) ?? String(data: sub, encoding: .isoLatin1) ?? ""
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("(") && s.hasSuffix(")") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func illustratorMajorVersion(from creator1: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "Illustrator[^ ]* ([.\\d]+)"),
              let match = regex.firstMatch(in: creator1, range: NSRange(creator1.startIndex..., in: creator1)),
              let range = Range(match.range(at: 1), in: creator1) else { return nil }
        return Int(String(creator1[range]).components(separatedBy: ".").first ?? "")
    }

    // MARK: - バージョン判定

    private static func determineVersion(fc: FileClass) {
        // AI8 以前の旧フォーマット（AI8_CreatorVersion 無し・互換 Creator 無し）
        // 例: Illustrator 5.5J など。creator1 に "Adobe Illustrator(TM) 5.5J 95.01.01"
        // のような文字列が入っており、末尾は日付サフィックスのため versionNumberSuffix では拾えない。
        // この場合は creator1 の Illustrator 直後のバージョントークンを「作成」、互換は空欄とする。
        let isLegacyFormat = fc.ai8_CreatorVersion.isEmpty && fc.creator2.isEmpty
            && (fc.kind == "Ai" || fc.kind == "EPS")

        fc.determine_Created = fc.ai8_CreatorVersion

        if fc.isIllustratorFile {
            if isLegacyFormat {
                fc.determine_Created = extractLegacyCreatorVersion(fc.creator1)
                fc.determine_Saved = ""
            } else if fc.kind == "EPS" {
                fc.determine_Saved = fc.hasCreator2
                    ? versionNumberSuffix(fc.creator2)
                    : versionNumberSuffix(fc.creator1)
            } else {
                fc.determine_Saved = versionNumberSuffix(fc.creator1)
            }
        }

        let created = Int(fc.determine_Created.components(separatedBy: ".").first ?? "") ?? 0
        let saved   = Int(fc.determine_Saved.components(separatedBy:  ".").first ?? "") ?? 0

        if (17...23).contains(created) && saved == 17 {
            fc.isSavedLowerVersion = false
        } else if created >= 24 && saved == 24 {
            fc.isSavedLowerVersion = false
        } else if created > 0 && saved > 0 {
            fc.isSavedLowerVersion = (created != saved)
        }
    }

    private static func versionNumberSuffix(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "[.\\d]+$"),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range, in: s) else { return "" }
        return String(s[range])
    }

    // creator1 から Illustrator 直後の最初のバージョントークンを抽出する（旧フォーマット用）
    // 例: "Adobe Illustrator(TM) 5.5J 95.01.01" → "5.5J"
    //     "Adobe Illustrator(TM) 7.0"          → "7.0"
    // 末尾の日付サフィックス（95.01.01 など）は対象外。
    private static func extractLegacyCreatorVersion(_ creator1: String) -> String {
        guard let regex = try? NSRegularExpression(
                pattern: #"Illustrator[^ ]*\s+(\d+(?:\.\d+)?[A-Za-z]?)"#),
              let match = regex.firstMatch(in: creator1,
                                           range: NSRange(creator1.startIndex..., in: creator1)),
              let range = Range(match.range(at: 1), in: creator1) else { return "" }
        return String(creator1[range])
    }

    // MARK: - Utilities

    private static func resolveAlias(url: URL) -> URL? {
        guard let vals = try? url.resourceValues(forKeys: [.isAliasFileKey]),
              vals.isAliasFile == true else { return nil }
        return try? URL(resolvingAliasFileAt: url)
    }

    private static func microsecondsString(from start: Date) -> String {
        let us = Int(Date().timeIntervalSince(start) * 1_000_000)
        return "\(us)"
    }
}
