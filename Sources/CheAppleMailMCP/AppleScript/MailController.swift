import Foundation

/// Controller for Apple Mail via AppleScript
///
/// AppleScript calls are dispatched to a dedicated serial queue to avoid
/// blocking Swift's cooperative thread pool (which the MCP StdioTransport
/// needs for stdin/stdout I/O).
actor MailController {
    static let shared = MailController()

    /// Dedicated queue for blocking NSAppleScript calls — keeps the
    /// cooperative thread pool free for MCP transport I/O.
    private static let scriptQueue = DispatchQueue(
        label: "com.che.applescript",
        qos: .userInitiated
    )

    private init() {}

    // MARK: - AppleScript Execution

    /// Execute AppleScript and return result (non-blocking to cooperative pool)
    func runScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Self.scriptQueue.async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: MailError.scriptCreationFailed)
                    return
                }

                let result = script.executeAndReturnError(&error)

                if let error = error {
                    let message = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error"
                    let code = error["NSAppleScriptErrorNumber"] as? Int ?? -1
                    continuation.resume(throwing: MailError.scriptFailed(message: message, code: code))
                } else {
                    continuation.resume(returning: result.stringValue ?? "")
                }
            }
        }
    }

    /// Execute AppleScript and return result as list (non-blocking to cooperative pool)
    func runScriptAsList(_ source: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            Self.scriptQueue.async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: MailError.scriptCreationFailed)
                    return
                }

                let result = script.executeAndReturnError(&error)

                if let error = error {
                    let message = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error"
                    let code = error["NSAppleScriptErrorNumber"] as? Int ?? -1
                    continuation.resume(throwing: MailError.scriptFailed(message: message, code: code))
                    return
                }

                // Parse list result
                var items: [String] = []
                let count = result.numberOfItems
                if count > 0 {
                    for i in 1...count {
                        if let item = result.atIndex(i)?.stringValue {
                            items.append(item)
                        }
                    }
                }
                continuation.resume(returning: items)
            }
        }
    }

    // MARK: - Account Operations

    /// List all mail accounts
    func listAccounts() async throws -> [[String: Any]] {
        let script = """
        tell application "Mail"
            set accountList to {}
            repeat with acc in accounts
                set accInfo to {|name|:name of acc, |id|:id of acc, |enabled|:enabled of acc, |type|:account type of acc as string}
                set end of accountList to accInfo
            end repeat
            return accountList
        end tell
        """

        // For simplicity, get names and basic info
        let namesScript = """
        tell application "Mail"
            get name of every account
        end tell
        """

        let names = try await runScriptAsList(namesScript)

        return names.map { name in
            ["name": name]
        }
    }

    /// Get account details
    func getAccountInfo(accountName: String) async throws -> [String: Any] {
        let script = """
        tell application "Mail"
            set acc to account "\(escapeForAppleScript(accountName))"
            return {|name|:name of acc, |enabled|:enabled of acc, |email|:email addresses of acc}
        end tell
        """

        let enabledScript = """
        tell application "Mail"
            get enabled of account "\(escapeForAppleScript(accountName))"
        end tell
        """

        let emailsScript = """
        tell application "Mail"
            get email addresses of account "\(escapeForAppleScript(accountName))"
        end tell
        """

        let enabled = try await runScript(enabledScript)
        let emails = try await runScriptAsList(emailsScript)

        return [
            "name": accountName,
            "enabled": enabled == "true",
            "email_addresses": emails
        ]
    }

    // MARK: - Mailbox Operations

    /// List mailboxes for an account
    func listMailboxes(accountName: String? = nil) async throws -> [[String: Any]] {
        let script: String
        if let account = accountName {
            script = """
            tell application "Mail"
                set mbList to {}
                repeat with mb in mailboxes of account "\(escapeForAppleScript(account))"
                    set mbInfo to {|name|:name of mb, |unreadCount|:unread count of mb, |messageCount|:count of messages of mb}
                    set end of mbList to mbInfo
                end repeat
                return mbList
            end tell
            """
        } else {
            script = """
            tell application "Mail"
                set mbList to {}
                repeat with acc in accounts
                    repeat with mb in mailboxes of acc
                        set mbInfo to {|name|:name of mb, |account|:name of acc, |unreadCount|:unread count of mb}
                        set end of mbList to mbInfo
                    end repeat
                end repeat
                return mbList
            end tell
            """
        }

        // Simplified: get mailbox names
        let namesScript: String
        if let account = accountName {
            namesScript = """
            tell application "Mail"
                get name of every mailbox of account "\(escapeForAppleScript(account))"
            end tell
            """
        } else {
            namesScript = """
            tell application "Mail"
                set allNames to {}
                repeat with acc in accounts
                    set accMailboxes to name of every mailbox of acc
                    set allNames to allNames & accMailboxes
                end repeat
                return allNames
            end tell
            """
        }

        let names = try await runScriptAsList(namesScript)

        return names.map { name in
            var info: [String: Any] = ["name": name]
            if let account = accountName {
                info["account"] = account
            }
            return info
        }
    }

    /// Create a new mailbox
    func createMailbox(name: String, accountName: String) async throws -> String {
        let script = """
        tell application "Mail"
            make new mailbox with properties {name:"\(escapeForAppleScript(name))"} at account "\(escapeForAppleScript(accountName))"
            return "Created mailbox: \(escapeForAppleScript(name))"
        end tell
        """
        return try await runScript(script)
    }

    /// Delete a mailbox
    func deleteMailbox(name: String, accountName: String) async throws -> String {
        let script = """
        tell application "Mail"
            delete mailbox "\(escapeForAppleScript(name))" of account "\(escapeForAppleScript(accountName))"
            return "Deleted mailbox: \(escapeForAppleScript(name))"
        end tell
        """
        return try await runScript(script)
    }

    // MARK: - Email Operations

    // MARK: - Delimiter-based parsing helpers

    /// Field delimiter within a record
    private static let fieldDelimiter = "|||"
    /// Record delimiter between records
    private static let recordDelimiter = "<<<>>>"

    /// Parse a delimiter-separated string into an array of field arrays
    private func parseDelimitedRecords(_ raw: String, fieldCount: Int) -> [[String]] {
        guard !raw.isEmpty else { return [] }
        let records = raw.components(separatedBy: Self.recordDelimiter)
        return records.compactMap { record in
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let fields = trimmed.components(separatedBy: Self.fieldDelimiter)
            guard fields.count >= fieldCount else { return nil }
            return fields
        }
    }

    /// Helper to build mailbox-scoped vectorized property fetch script
    private func vectorizedFetchScript(property: String, mailbox: String, accountName: String, limit: Int) -> String {
        """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(accountName))"
            set msgCount to count of messages of mb
            if msgCount = 0 then return {}
            if \(limit) < msgCount then
                set actualLimit to \(limit)
            else
                set actualLimit to msgCount
            end if
            get \(property) of messages 1 thru actualLimit of mb
        end tell
        """
    }

    /// List emails in a mailbox using vectorized property access (3 fast Apple Events)
    func listEmails(mailbox: String, accountName: String, limit: Int = 50) async throws -> [[String: Any]] {
        let ids = try await runScriptAsList(vectorizedFetchScript(property: "id", mailbox: mailbox, accountName: accountName, limit: limit))
        guard !ids.isEmpty else { return [] }

        let subjects = try await runScriptAsList(vectorizedFetchScript(property: "subject", mailbox: mailbox, accountName: accountName, limit: limit))
        let senders = try await runScriptAsList(vectorizedFetchScript(property: "sender", mailbox: mailbox, accountName: accountName, limit: limit))

        var emails: [[String: Any]] = []
        for i in 0..<min(ids.count, subjects.count, senders.count) {
            emails.append([
                "id": ids[i],
                "subject": subjects[i],
                "sender": senders[i]
            ])
        }
        return emails
    }

    /// Get email content by ID (single AppleScript call for metadata + content)
    /// - format: "html" (default) returns HTML body with links preserved;
    ///           "text" returns plain text content;
    ///           "source" returns full MIME source
    func getEmail(id: String, mailbox: String, accountName: String, format: String = "html") async throws -> [String: Any] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)

        // Fetch metadata + content in a single AppleScript call
        let contentProp: String
        switch format {
        case "text":
            contentProp = "content of msg"
        case "source":
            contentProp = "source of msg"
        default: // "html" — fetch source, extract HTML in Swift
            contentProp = "source of msg"
        }

        let script = """
        tell application "Mail"
            set msg to \(ref)
            set msgSubject to subject of msg
            set msgSender to sender of msg
            set msgDate to date received of msg as string
            set msgRead to read status of msg as string
            set msgContent to \(contentProp)
            set toRecips to ""
            repeat with r in (to recipients of msg)
                if toRecips is not "" then set toRecips to toRecips & ", "
                set toRecips to toRecips & (address of r) & " (" & (name of r) & ")"
            end repeat
            set ccRecips to ""
            repeat with r in (cc recipients of msg)
                if ccRecips is not "" then set ccRecips to ccRecips & ", "
                set ccRecips to ccRecips & (address of r) & " (" & (name of r) & ")"
            end repeat
            return msgSubject & "<<<FIELD>>>" & msgSender & "<<<FIELD>>>" & msgDate & "<<<FIELD>>>" & msgRead & "<<<FIELD>>>" & toRecips & "<<<FIELD>>>" & ccRecips & "<<<FIELD>>>" & msgContent
        end tell
        """

        let raw = try await runScript(script)
        let parts = raw.components(separatedBy: "<<<FIELD>>>")

        guard parts.count >= 7 else {
            throw MailError.scriptFailed(message: "Unexpected response format from getEmail", code: -1)
        }

        let subject = parts[0]
        let sender = parts[1]
        let dateReceived = parts[2]
        let readStatus = parts[3]
        let toRecipients = parts[4]
        let ccRecipients = parts[5]
        let rawContent = parts[6...].joined(separator: "<<<FIELD>>>") // content may contain the delimiter

        let content: String
        if format == "html" {
            content = extractHTMLBody(from: rawContent)
        } else {
            content = rawContent
        }

        return [
            "id": id,
            "subject": subject,
            "sender": sender,
            "date_received": dateReceived,
            "read": readStatus == "true",
            "to": toRecipients,
            "cc": ccRecipients,
            "format": format,
            "content": content
        ]
    }

    /// Batch get multiple emails by ID in a single AppleScript call
    /// Returns text content for each email (most token-efficient for LLM consumption)
    func batchGetEmails(ids: [String], mailbox: String, accountName: String) async throws -> [[String: Any]] {
        guard !ids.isEmpty else { return [] }

        // Build AppleScript that fetches all emails in one tell block
        let idsLiteral = ids.joined(separator: ", ")
        let script = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(accountName))"
            set idList to {\(idsLiteral)}
            set output to ""
            repeat with targetId in idList
                set msg to (first message of mb whose id is targetId)
                set msgSubject to subject of msg
                set msgSender to sender of msg
                set msgDate to date received of msg as string
                set msgContent to content of msg
                set toRecips to ""
                repeat with r in (to recipients of msg)
                    if toRecips is not "" then set toRecips to toRecips & ", "
                    set toRecips to toRecips & (address of r)
                end repeat
                set ccRecips to ""
                repeat with r in (cc recipients of msg)
                    if ccRecips is not "" then set ccRecips to ccRecips & ", "
                    set ccRecips to ccRecips & (address of r)
                end repeat
                if output is not "" then set output to output & "<<<REC>>>"
                set output to output & (targetId as string) & "<<<F>>>" & msgSubject & "<<<F>>>" & msgSender & "<<<F>>>" & msgDate & "<<<F>>>" & toRecips & "<<<F>>>" & ccRecips & "<<<F>>>" & msgContent
            end repeat
            return output
        end tell
        """

        let raw = try await runScript(script)
        guard !raw.isEmpty else { return [] }

        let records = raw.components(separatedBy: "<<<REC>>>")
        return records.compactMap { record in
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.components(separatedBy: "<<<F>>>")
            guard parts.count >= 7 else { return nil }
            return [
                "id": parts[0],
                "subject": parts[1],
                "sender": parts[2],
                "date_received": parts[3],
                "to": parts[4],
                "cc": parts[5],
                "content": parts[6...].joined(separator: "<<<F>>>") // content may contain delimiter
            ] as [String: Any]
        }
    }

    /// Batch move multiple emails to a target mailbox in a single AppleScript call
    func batchMoveEmails(ids: [String], fromMailbox: String, toMailbox: String, accountName: String) async throws -> String {
        guard !ids.isEmpty else { return "No emails to move" }

        let idsLiteral = ids.joined(separator: ", ")
        let script = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(fromMailbox))" of account "\(escapeForAppleScript(accountName))"
            set targetMb to mailbox "\(escapeForAppleScript(toMailbox))" of account "\(escapeForAppleScript(accountName))"
            set idList to {\(idsLiteral)}
            set movedCount to 0
            repeat with targetId in idList
                try
                    set msg to (first message of mb whose id is targetId)
                    move msg to targetMb
                    set movedCount to movedCount + 1
                end try
            end repeat
            return "Moved " & (movedCount as string) & " of " & ((count of idList) as string) & " emails to " & "\(escapeForAppleScript(toMailbox))"
        end tell
        """

        return try await runScript(script)
    }

    /// Batch delete multiple emails in a single AppleScript call
    func batchDeleteEmails(ids: [String], mailbox: String, accountName: String) async throws -> String {
        guard !ids.isEmpty else { return "No emails to delete" }

        let idsLiteral = ids.joined(separator: ", ")
        let script = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(accountName))"
            set idList to {\(idsLiteral)}
            set deletedCount to 0
            repeat with targetId in idList
                try
                    set msg to (first message of mb whose id is targetId)
                    delete msg
                    set deletedCount to deletedCount + 1
                end try
            end repeat
            return "Deleted " & (deletedCount as string) & " of " & ((count of idList) as string) & " emails"
        end tell
        """

        return try await runScript(script)
    }

    /// Extract HTML body from MIME source, falling back to plain text content
    private func extractHTMLBody(from mimeSource: String) -> String {
        // Look for text/html part in multipart message
        // Find the HTML content between Content-Type: text/html and the next boundary
        let lines = mimeSource.components(separatedBy: "\n")
        var inHTMLPart = false
        var pastHTMLHeaders = false
        var htmlLines: [String] = []
        var boundary: String?

        // Find boundary from Content-Type header
        for line in lines {
            if line.contains("boundary=") {
                if let range = line.range(of: "boundary=\"") {
                    let start = range.upperBound
                    if let end = line[start...].firstIndex(of: "\"") {
                        boundary = String(line[start..<end])
                    }
                } else if let range = line.range(of: "boundary=") {
                    let start = range.upperBound
                    boundary = line[start...].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        for line in lines {
            if line.contains("Content-Type: text/html") {
                inHTMLPart = true
                pastHTMLHeaders = false
                continue
            }

            if inHTMLPart && !pastHTMLHeaders {
                // Skip headers until empty line
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pastHTMLHeaders = true
                }
                continue
            }

            if inHTMLPart && pastHTMLHeaders {
                // Check for boundary end
                if let b = boundary, line.contains(b) {
                    break
                }
                htmlLines.append(line)
            }
        }

        if htmlLines.isEmpty {
            return mimeSource // Fallback: return raw source if no HTML found
        }

        var html = htmlLines.joined(separator: "\n")

        // Decode quoted-printable encoding
        html = decodeQuotedPrintable(html)

        return html
    }

    /// Decode quoted-printable encoded string
    private func decodeQuotedPrintable(_ input: String) -> String {
        var result = input
        // Remove soft line breaks (= at end of line)
        result = result.replacingOccurrences(of: "=\r\n", with: "")
        result = result.replacingOccurrences(of: "=\n", with: "")

        // Decode =XX hex sequences
        var output = ""
        var i = result.startIndex
        while i < result.endIndex {
            if result[i] == "=" && result.distance(from: i, to: result.endIndex) >= 3 {
                let hexStart = result.index(after: i)
                let hexEnd = result.index(hexStart, offsetBy: 2)
                let hex = String(result[hexStart..<hexEnd])
                if let byte = UInt8(hex, radix: 16) {
                    output.append(Character(Unicode.Scalar(byte)))
                } else {
                    output.append(result[i])
                }
                i = hexEnd
            } else {
                output.append(result[i])
                i = result.index(after: i)
            }
        }

        return output
    }

    /// Search emails
    func searchEmails(query: String, mailbox: String? = nil, accountName: String? = nil, limit: Int = 20, sort: String = "desc") async throws -> [[String: Any]] {
        let escapedQuery = escapeForAppleScript(query)
        let sep = "⏐"  // Separator unlikely to appear in email fields

        let script: String
        if let mailbox = mailbox, let accountName = accountName {
            // Search specific mailbox of specific account
            script = """
            tell application "Mail"
                set foundMsgs to (messages of mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(accountName))" whose subject contains "\(escapedQuery)" or sender contains "\(escapedQuery)")
                set results to {}
                set counter to 0
                repeat with msg in foundMsgs
                    if counter ≥ \(limit) then exit repeat
                    set end of results to (id of msg as string) & "\(sep)" & (subject of msg) & "\(sep)" & (sender of msg) & "\(sep)" & (date received of msg as string) & "\(sep)" & "\(escapeForAppleScript(accountName))" & "\(sep)" & "\(escapeForAppleScript(mailbox))"
                    set counter to counter + 1
                end repeat
                return results
            end tell
            """
        } else {
            // Search across all accounts and mailboxes
            script = """
            tell application "Mail"
                set results to {}
                set counter to 0
                repeat with acct in every account
                    if (enabled of acct) then
                        set acctName to name of acct
                        repeat with mbox in every mailbox of acct
                            try
                                set mboxName to name of mbox
                                set foundMsgs to (messages of mbox whose subject contains "\(escapedQuery)" or sender contains "\(escapedQuery)")
                                repeat with msg in foundMsgs
                                    if counter ≥ \(limit) then exit repeat
                                    set end of results to (id of msg as string) & "\(sep)" & (subject of msg) & "\(sep)" & (sender of msg) & "\(sep)" & (date received of msg as string) & "\(sep)" & acctName & "\(sep)" & mboxName
                                    set counter to counter + 1
                                end repeat
                            end try
                            if counter ≥ \(limit) then exit repeat
                        end repeat
                    end if
                    if counter ≥ \(limit) then exit repeat
                end repeat
                return results
            end tell
            """
        }

        let rows = try await runScriptAsList(script)

        var emails: [[String: Any]] = []
        for row in rows {
            let fields = row.components(separatedBy: sep)
            guard fields.count >= 6 else { continue }
            emails.append([
                "id": fields[0],
                "subject": fields[1],
                "sender": fields[2],
                "date_received": fields[3],
                "account_name": fields[4],
                "mailbox": fields[5]
            ])
        }

        // Sort by date_received string (Apple Mail returns localized date strings)
        if sort == "asc" {
            emails.reverse()  // Apple Mail returns newest first, reverse for ascending
        }
        // "desc" (default) = newest first, which is Apple Mail's natural order

        return emails
    }

    /// Get unread count
    func getUnreadCount(mailbox: String? = nil, accountName: String? = nil) async throws -> Int {
        let script: String
        if let mailbox = mailbox, let account = accountName {
            script = """
            tell application "Mail"
                get unread count of mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(account))"
            end tell
            """
        } else if let account = accountName {
            script = """
            tell application "Mail"
                set total to 0
                repeat with mb in mailboxes of account "\(escapeForAppleScript(account))"
                    set total to total + (unread count of mb)
                end repeat
                return total
            end tell
            """
        } else {
            script = """
            tell application "Mail"
                set total to 0
                repeat with acc in accounts
                    repeat with mb in mailboxes of acc
                        set total to total + (unread count of mb)
                    end repeat
                end repeat
                return total
            end tell
            """
        }

        let result = try await runScript(script)
        return Int(result) ?? 0
    }

    // MARK: - Email Actions

    /// Mark email as read/unread
    func markRead(id: String, mailbox: String, accountName: String, read: Bool) async throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set read status of \(ref) to \(read)
            return "Email marked as \(read ? "read" : "unread")"
        end tell
        """
        return try await runScript(script)
    }

    /// Flag email
    func flagEmail(id: String, mailbox: String, accountName: String, flagged: Bool) async throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set flagged status of \(ref) to \(flagged)
            return "Email \(flagged ? "flagged" : "unflagged")"
        end tell
        """
        return try await runScript(script)
    }

    /// Move email to another mailbox
    func moveEmail(id: String, fromMailbox: String, toMailbox: String, accountName: String) async throws -> String {
        let ref = msgRef(id, mailbox: fromMailbox, account: accountName)
        let script = """
        tell application "Mail"
            set msg to \(ref)
            move msg to mailbox "\(escapeForAppleScript(toMailbox))" of account "\(escapeForAppleScript(accountName))"
            return "Email moved to \(escapeForAppleScript(toMailbox))"
        end tell
        """
        return try await runScript(script)
    }

    /// Delete email (move to trash)
    func deleteEmail(id: String, mailbox: String, accountName: String) async throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            delete \(ref)
            return "Email deleted"
        end tell
        """
        return try await runScript(script)
    }

    // MARK: - Compose Operations

    /// Validate that all file paths exist, throwing with a clear message if any are missing
    private func validateFilePaths(_ paths: [String]) throws {
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else {
            throw MailError.invalidParameter("File(s) not found: \(missing.joined(separator: ", "))")
        }
    }

    /// Generate AppleScript lines to attach files to an outgoing message
    private func attachmentScript(for paths: [String]) -> String {
        paths.map { path in
            """
                make new attachment with properties {file name:POSIX file "\(escapeForAppleScript(path))"} at after the last paragraph
            """
        }.joined()
    }

    /// Compose and send a new email
    func composeEmail(to: [String], subject: String, body: String, cc: [String]? = nil, bcc: [String]? = nil, attachments: [String]? = nil, accountName: String? = nil) async throws -> String {
        if let attachments = attachments { try validateFilePaths(attachments) }

        var script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(escapeForAppleScript(subject))", content:"\(escapeForAppleScript(body))", visible:true}
            tell newMessage
        """

        for recipient in to {
            script += """
                make new to recipient at end of to recipients with properties {address:"\(escapeForAppleScript(recipient))"}
            """
        }

        if let cc = cc {
            for recipient in cc {
                script += """
                    make new cc recipient at end of cc recipients with properties {address:"\(escapeForAppleScript(recipient))"}
                """
            }
        }

        if let bcc = bcc {
            for recipient in bcc {
                script += """
                    make new bcc recipient at end of bcc recipients with properties {address:"\(escapeForAppleScript(recipient))"}
                """
            }
        }

        if let attachments = attachments {
            script += attachmentScript(for: attachments)
        }

        script += """
            end tell
            send newMessage
            return "Email sent successfully"
        end tell
        """

        return try await runScript(script)
    }

    /// Reply to an email
    func replyEmail(id: String, mailbox: String, accountName: String, body: String, replyAll: Bool = false) async throws -> String {
        let replyType = replyAll ? "reply all" : "reply"
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set originalMsg to \(ref)
            set replyMsg to \(replyType) originalMsg with opening window
            tell replyMsg
                set content to "\(escapeForAppleScript(body))" & return & return & content
            end tell
            send replyMsg
            return "Reply sent successfully"
        end tell
        """
        return try await runScript(script)
    }

    /// Forward an email
    func forwardEmail(id: String, mailbox: String, accountName: String, to: [String], body: String? = nil) async throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        var script = """
        tell application "Mail"
            set originalMsg to \(ref)
            set fwdMsg to forward originalMsg with opening window
            tell fwdMsg
        """

        for recipient in to {
            script += """
                make new to recipient at end of to recipients with properties {address:"\(escapeForAppleScript(recipient))"}
            """
        }

        if let body = body {
            script += """
                set content to "\(escapeForAppleScript(body))" & return & return & content
            """
        }

        script += """
            end tell
            send fwdMsg
            return "Email forwarded successfully"
        end tell
        """

        return try await runScript(script)
    }

    // MARK: - Draft Operations

    /// List drafts
    func listDrafts(accountName: String) async throws -> [[String: Any]] {
        let script = """
        tell application "Mail"
            get subject of messages of mailbox "Drafts" of account "\(escapeForAppleScript(accountName))"
        end tell
        """

        let subjects = try await runScriptAsList(script)

        return subjects.map { subject in
            ["subject": subject]
        }
    }

    /// Create a draft
    func createDraft(to: [String], subject: String, body: String, attachments: [String]? = nil, accountName: String? = nil) async throws -> String {
        if let attachments = attachments { try validateFilePaths(attachments) }

        var script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(escapeForAppleScript(subject))", content:"\(escapeForAppleScript(body))", visible:true}
            tell newMessage
        """

        for recipient in to {
            script += """
                make new to recipient at end of to recipients with properties {address:"\(escapeForAppleScript(recipient))"}
            """
        }

        if let attachments = attachments {
            script += attachmentScript(for: attachments)
        }

        script += """
            end tell
            save newMessage
            return "Draft created successfully"
        end tell
        """

        return try await runScript(script)
    }

    // MARK: - Attachment Operations

    /// List attachments of an email
    func listAttachments(id: String, mailbox: String, accountName: String) async throws -> [[String: Any]] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set msg to \(ref)
            set attachmentList to {}
            repeat with att in mail attachments of msg
                set attInfo to {|name|:name of att, |size|:file size of att}
                set end of attachmentList to attInfo
            end repeat
            return attachmentList
        end tell
        """

        let namesScript = """
        tell application "Mail"
            get name of every mail attachment of \(ref)
        end tell
        """

        let names = try await runScriptAsList(namesScript)

        return names.map { name in
            ["name": name]
        }
    }

    /// Save attachment to disk
    func saveAttachment(id: String, mailbox: String, accountName: String, attachmentName: String, savePath: String) async throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set msg to \(ref)
            repeat with att in mail attachments of msg
                if name of att is "\(escapeForAppleScript(attachmentName))" then
                    save att in POSIX file "\(escapeForAppleScript(savePath))"
                    return "Attachment saved to \(escapeForAppleScript(savePath))"
                end if
            end repeat
            return "Attachment not found"
        end tell
        """
        return try await runScript(script)
    }

    // MARK: - VIP Operations

    /// List VIP senders
    func listVIPSenders() async throws -> [String] {
        let script = """
        tell application "Mail"
            get sender of messages of mailbox "VIP"
        end tell
        """

        return try await runScriptAsList(script)
    }

    // MARK: - Rule Operations

    /// List mail rules
    func listRules() async throws -> [[String: Any]] {
        let script = """
        tell application "Mail"
            get name of every rule
        end tell
        """

        let names = try await runScriptAsList(script)

        return names.map { name in
            ["name": name]
        }
    }

    /// Enable/disable a rule
    func enableRule(name: String, enabled: Bool) async throws -> String {
        let script = """
        tell application "Mail"
            set enabled of rule "\(escapeForAppleScript(name))" to \(enabled)
            return "Rule '\(escapeForAppleScript(name))' \(enabled ? "enabled" : "disabled")"
        end tell
        """
        return try await runScript(script)
    }

    /// Get detailed rule information
    func getRuleDetails(name: String) async throws -> [String: Any] {
        let enabledScript = """
        tell application "Mail"
            get enabled of rule "\(escapeForAppleScript(name))"
        end tell
        """

        let allConditionsScript = """
        tell application "Mail"
            get all conditions must be met of rule "\(escapeForAppleScript(name))"
        end tell
        """

        let stopScript = """
        tell application "Mail"
            get stop evaluating rules of rule "\(escapeForAppleScript(name))"
        end tell
        """

        let enabled = try await runScript(enabledScript) == "true"
        let allConditions = try await runScript(allConditionsScript) == "true"
        let stopEvaluating = try await runScript(stopScript) == "true"

        return [
            "name": name,
            "enabled": enabled,
            "all_conditions_must_be_met": allConditions,
            "stop_evaluating_rules": stopEvaluating
        ]
    }

    /// Create a simple mail rule
    func createRule(name: String, conditions: [[String: String]], actions: [String: Any]) async throws -> String {
        var script = """
        tell application "Mail"
            set newRule to make new rule with properties {name:"\(escapeForAppleScript(name))"}
        """

        // Add conditions
        for condition in conditions {
            if let header = condition["header"],
               let qualifier = condition["qualifier"],
               let expression = condition["expression"] {
                script += """
                    tell newRule
                        make new rule condition with properties {rule type:header rule, header:"\(escapeForAppleScript(header))", qualifier:\(qualifier), expression:"\(escapeForAppleScript(expression))"}
                    end tell
                """
            }
        }

        // Add actions
        if let moveMailbox = actions["move_message"] as? String {
            script += """
                set move message of newRule to mailbox "\(escapeForAppleScript(moveMailbox))"
            """
        }

        if let markRead = actions["mark_read"] as? Bool {
            script += """
                set mark read of newRule to \(markRead)
            """
        }

        if let markFlagged = actions["mark_flagged"] as? Bool {
            script += """
                set mark flagged of newRule to \(markFlagged)
            """
        }

        if let deleteMessage = actions["delete_message"] as? Bool {
            script += """
                set delete message of newRule to \(deleteMessage)
            """
        }

        script += """
            return "Rule '\(escapeForAppleScript(name))' created successfully"
        end tell
        """

        return try await runScript(script)
    }

    /// Delete a rule
    func deleteRule(name: String) async throws -> String {
        let script = """
        tell application "Mail"
            delete rule "\(escapeForAppleScript(name))"
            return "Rule '\(escapeForAppleScript(name))' deleted"
        end tell
        """
        return try await runScript(script)
    }

    // MARK: - Mail Check & Sync Operations

    /// Check for new mail
    func checkForNewMail(accountName: String? = nil) async throws -> String {
        let script: String
        if let account = accountName {
            script = """
            tell application "Mail"
                check for new mail for account "\(escapeForAppleScript(account))"
                return "Checking for new mail in \(escapeForAppleScript(account))"
            end tell
            """
        } else {
            script = """
            tell application "Mail"
                check for new mail
                return "Checking for new mail in all accounts"
            end tell
            """
        }
        return try await runScript(script)
    }

    /// Synchronize IMAP account
    func synchronizeAccount(accountName: String) async throws -> String {
        let script = """
        tell application "Mail"
            synchronize account "\(escapeForAppleScript(accountName))"
            return "Synchronizing account: \(escapeForAppleScript(accountName))"
        end tell
        """
        return try await runScript(script)
    }

    // MARK: - Advanced Email Operations

    /// Copy email to another mailbox
    func copyEmail(id: String, fromMailbox: String, toMailbox: String, accountName: String) async throws -> String {
        let ref = msgRef(id, mailbox: fromMailbox, account: accountName)
        let script = """
        tell application "Mail"
            set msg to \(ref)
            duplicate msg to mailbox "\(escapeForAppleScript(toMailbox))" of account "\(escapeForAppleScript(accountName))"
            return "Email copied to \(escapeForAppleScript(toMailbox))"
        end tell
        """
        return try await runScript(script)
    }

    /// Set flag color (0-6: red, orange, yellow, green, blue, purple, gray; -1 to clear)
    func setFlagColor(id: String, mailbox: String, accountName: String, colorIndex: Int) async throws -> String {
        let colors = ["red", "orange", "yellow", "green", "blue", "purple", "gray"]
        let colorName = colorIndex >= 0 && colorIndex < colors.count ? colors[colorIndex] : "none"

        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set flag index of \(ref) to \(colorIndex)
            return "Flag color set to \(colorName)"
        end tell
        """
        return try await runScript(script)
    }

    /// Set email background color
    func setBackgroundColor(id: String, mailbox: String, accountName: String, color: String) async throws -> String {
        // Valid colors: blue, gray, green, none, orange, purple, red, yellow
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set background color of \(ref) to \(color)
            return "Background color set to \(color)"
        end tell
        """
        return try await runScript(script)
    }

    /// Mark email as junk or not junk
    func markAsJunk(id: String, mailbox: String, accountName: String, isJunk: Bool) async throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set junk mail status of \(ref) to \(isJunk)
            return "Email marked as \(isJunk ? "junk" : "not junk")"
        end tell
        """
        return try await runScript(script)
    }

    /// Get all email headers
    func getEmailHeaders(id: String, mailbox: String, accountName: String) async throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            get all headers of \(ref)
        end tell
        """
        return try await runScript(script)
    }

    /// Get email source (raw message)
    func getEmailSource(id: String, mailbox: String, accountName: String) async throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            get source of \(ref)
        end tell
        """
        return try await runScript(script)
    }

    /// Redirect email (different from forward - keeps original sender)
    func redirectEmail(id: String, mailbox: String, accountName: String, to: [String]) async throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        var script = """
        tell application "Mail"
            set originalMsg to \(ref)
            set redirectMsg to redirect originalMsg with opening window
            tell redirectMsg
        """

        for recipient in to {
            script += """
                make new to recipient at end of to recipients with properties {address:"\(escapeForAppleScript(recipient))"}
            """
        }

        script += """
            end tell
            send redirectMsg
            return "Email redirected successfully"
        end tell
        """

        return try await runScript(script)
    }

    /// Get email metadata (was forwarded, replied to, redirected)
    func getEmailMetadata(id: String, mailbox: String, accountName: String) async throws -> [String: Any] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)

        let forwardedScript = """
        tell application "Mail"
            get was forwarded of \(ref)
        end tell
        """

        let repliedScript = """
        tell application "Mail"
            get was replied to of \(ref)
        end tell
        """

        let redirectedScript = """
        tell application "Mail"
            get was redirected of \(ref)
        end tell
        """

        let messageIdScript = """
        tell application "Mail"
            get message id of \(ref)
        end tell
        """

        let sizeScript = """
        tell application "Mail"
            get message size of \(ref)
        end tell
        """

        let wasForwarded = try await runScript(forwardedScript) == "true"
        let wasReplied = try await runScript(repliedScript) == "true"
        let wasRedirected = try await runScript(redirectedScript) == "true"
        let msgId = try await runScript(messageIdScript)
        let size = try await runScript(sizeScript)

        return [
            "was_forwarded": wasForwarded,
            "was_replied_to": wasReplied,
            "was_redirected": wasRedirected,
            "message_id": msgId,
            "size_bytes": Int(size) ?? 0
        ]
    }

    // MARK: - Signature Operations

    /// List all signatures
    func listSignatures() async throws -> [[String: Any]] {
        // First check if there are any signatures
        let countScript = """
        tell application "Mail"
            get count of signatures
        end tell
        """

        let countResult = try await runScript(countScript)
        guard let count = Int(countResult), count > 0 else {
            return []
        }

        let namesScript = """
        tell application "Mail"
            get name of every signature
        end tell
        """

        let names = try await runScriptAsList(namesScript)

        return names.map { name in
            ["name": name]
        }
    }

    /// Get signature content
    func getSignature(name: String) async throws -> [String: Any] {
        let contentScript = """
        tell application "Mail"
            get content of signature "\(escapeForAppleScript(name))"
        end tell
        """

        let content = try await runScript(contentScript)

        return [
            "name": name,
            "content": content
        ]
    }

    // MARK: - SMTP Server Operations

    /// List SMTP servers
    func listSMTPServers() async throws -> [[String: Any]] {
        let namesScript = """
        tell application "Mail"
            get name of every smtp server
        end tell
        """

        let serverNamesScript = """
        tell application "Mail"
            get server name of every smtp server
        end tell
        """

        let names = try await runScriptAsList(namesScript)
        let serverNames = try await runScriptAsList(serverNamesScript)

        var servers: [[String: Any]] = []
        for i in 0..<names.count {
            var server: [String: Any] = ["name": names[i]]
            if i < serverNames.count {
                server["server_name"] = serverNames[i]
            }
            servers.append(server)
        }

        return servers
    }

    // MARK: - Special Mailboxes

    /// Get special mailboxes (inbox, drafts, sent, trash, junk, outbox)
    func getSpecialMailboxes() async throws -> [String: Any] {
        let inboxScript = """
        tell application "Mail"
            get name of inbox
        end tell
        """

        let draftsScript = """
        tell application "Mail"
            get name of drafts mailbox
        end tell
        """

        let sentScript = """
        tell application "Mail"
            get name of sent mailbox
        end tell
        """

        let trashScript = """
        tell application "Mail"
            get name of trash mailbox
        end tell
        """

        let junkScript = """
        tell application "Mail"
            get name of junk mailbox
        end tell
        """

        let outboxScript = """
        tell application "Mail"
            get name of outbox
        end tell
        """

        return [
            "inbox": try await runScript(inboxScript),
            "drafts": try await runScript(draftsScript),
            "sent": try await runScript(sentScript),
            "trash": try await runScript(trashScript),
            "junk": try await runScript(junkScript),
            "outbox": try await runScript(outboxScript)
        ]
    }

    // MARK: - Address Operations

    /// Extract name from email address
    func extractNameFromAddress(address: String) async throws -> String {
        let script = """
        tell application "Mail"
            extract name from "\(escapeForAppleScript(address))"
        end tell
        """
        return try await runScript(script)
    }

    /// Extract email address from full address string
    func extractAddressFrom(address: String) async throws -> String {
        let script = """
        tell application "Mail"
            extract address from "\(escapeForAppleScript(address))"
        end tell
        """
        return try await runScript(script)
    }

    // MARK: - Application Operations

    /// Get Mail application info
    func getMailAppInfo() async throws -> [String: Any] {
        let versionScript = """
        tell application "Mail"
            get application version
        end tell
        """

        let fetchIntervalScript = """
        tell application "Mail"
            get fetch interval
        end tell
        """

        let backgroundCountScript = """
        tell application "Mail"
            get background activity count
        end tell
        """

        let version = try await runScript(versionScript)
        let fetchInterval = try await runScript(fetchIntervalScript)
        let bgCount = try await runScript(backgroundCountScript)

        return [
            "version": version,
            "fetch_interval_minutes": Int(fetchInterval) ?? -1,
            "background_activity_count": Int(bgCount) ?? 0
        ]
    }

    /// Open mailto URL
    func openMailtoURL(url: String) async throws -> String {
        let script = """
        tell application "Mail"
            mailto "\(escapeForAppleScript(url))"
            return "Opened mailto URL"
        end tell
        """
        return try await runScript(script)
    }

    // MARK: - Import/Export Operations

    /// Import mailbox from file
    func importMailbox(path: String) async throws -> String {
        let script = """
        tell application "Mail"
            import Mail mailbox POSIX file "\(escapeForAppleScript(path))"
            return "Mailbox imported from \(escapeForAppleScript(path))"
        end tell
        """
        return try await runScript(script)
    }

    // MARK: - Helpers

    /// Generate AppleScript reference to find a message by its numeric id.
    /// Apple Mail's `message id` refers to the RFC822 Message-ID (string),
    /// but `id` is the internal numeric identifier returned by search/list.
    /// We must use `first message ... whose id is N` instead of `message id N`.
    private func msgRef(_ id: String, mailbox: String, account: String) -> String {
        return "(first message of mailbox \"\(escapeForAppleScript(mailbox))\" of account \"\(escapeForAppleScript(account))\" whose id is \(id))"
    }

    /// Escape special characters for AppleScript strings.
    /// AppleScript does not support C-style escape sequences (\n, \t).
    /// Newlines must be expressed as: `" & return & "` string concatenation.
    private func escapeForAppleScript(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\" & return & \"")
            .replacingOccurrences(of: "\n", with: "\" & return & \"")
            .replacingOccurrences(of: "\r", with: "\" & return & \"")
            .replacingOccurrences(of: "\t", with: "\" & tab & \"")
    }
}

// MARK: - Mail Error

enum MailError: LocalizedError {
    case scriptCreationFailed
    case scriptFailed(message: String, code: Int)
    case invalidParameter(String)

    var errorDescription: String? {
        switch self {
        case .scriptCreationFailed:
            return "Failed to create AppleScript"
        case .scriptFailed(let message, let code):
            return "AppleScript error (\(code)): \(message)"
        case .invalidParameter(let message):
            return "Invalid parameter: \(message)"
        }
    }
}
