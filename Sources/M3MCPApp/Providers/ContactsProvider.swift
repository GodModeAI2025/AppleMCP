import Contacts
import Foundation
import M3MCPCore

final class ContactsProvider {
    static let maximumQueryUTF8Bytes = 4_096
    static let maximumContactValueEntries = 8
    static let maximumContactValueUTF8Bytes = 192
    static let maximumIdentifierUTF8Bytes = 512
    static let maximumNameUTF8Bytes = 512
    static let maximumOrganizationUTF8Bytes = 512

    // Constructing CNContactStore can establish an XPC/Core Data connection immediately. Keep it
    // lazy so malformed or oversized requests are rejected before the Contacts privacy boundary,
    // and so ordinary app startup does not touch the user's address book just by registering tools.
    private lazy var store = CNContactStore()

    func search(input: [String: JSONValue]) async -> ToolResponse {
        do {
            guard !Task.isCancelled else {
                return ToolResponse(ok: false, source: "Contacts", message: "Contacts request was cancelled.")
            }

            let query = input.string("query")
            guard query.utf8.count <= Self.maximumQueryUTF8Bytes else {
                return ToolResponse(
                    ok: false,
                    source: "Contacts",
                    message: "Contacts query exceeds the \(Self.maximumQueryUTF8Bytes)-byte work limit."
                )
            }

            guard hasReadAccess else {
                return ToolResponse(
                    ok: false,
                    source: "Contacts",
                    message: "Contacts access is not authorized. Grant it in System Settings, or explicitly enable and call permissions_request."
                )
            }

            let limit = max(1, min(input.int("limit", default: 25), 100))
            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactJobTitleKey as CNKeyDescriptor
            ]

            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let predicate = trimmedQuery.isEmpty
                ? nil
                : CNContact.predicateForContacts(matchingName: trimmedQuery)
            let page = try enumerateContacts(keys: keys, predicate: predicate, limit: limit)
            guard !Task.isCancelled else {
                return ToolResponse(ok: false, source: "Contacts", message: "Contacts request was cancelled.")
            }

            let items = page.contacts.map(Self.makeItem)
            return ToolResponse(
                ok: true,
                source: "Contacts",
                items: items,
                message: page.hasMore ? "More contacts matched; narrow the query or increase limit." : nil,
                meta: [
                    "returned": String(items.count),
                    "has_more": String(page.hasMore),
                    "truncated": String(page.hasMore),
                    "provider_callback_budget": String(limit + 1)
                ]
            )
        } catch {
            return ToolResponse(
                ok: false,
                source: "Contacts",
                message: StringSanitizer.compact(error.localizedDescription, limit: 800)
            )
        }
    }

    private static func displayName(for contact: CNContact) -> ProviderBoundedText {
        // Bound each component before trimming or joining it. A hostile Contacts store must not be
        // able to make one display-name concatenation allocate an arbitrarily large temporary.
        let boundedComponents = [contact.givenName, contact.familyName].map {
            ProviderOutputBudget.text($0, maximumUTF8Bytes: maximumNameUTF8Bytes)
        }
        let components = boundedComponents
        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        if !components.isEmpty {
            let joined = ProviderOutputBudget.text(
                components.joined(separator: " "),
                maximumUTF8Bytes: maximumNameUTF8Bytes
            )
            return ProviderBoundedText(
                text: joined.text,
                originalBytes: joined.originalBytes,
                truncated: joined.truncated || boundedComponents.contains(where: \.truncated)
            )
        }

        let organization = ProviderOutputBudget.text(
            contact.organizationName,
            maximumUTF8Bytes: maximumNameUTF8Bytes
        )
        return ProviderBoundedText(
            text: organization.text.trimmingCharacters(in: .whitespacesAndNewlines),
            originalBytes: organization.originalBytes,
            truncated: organization.truncated
        )
    }

    private var hasReadAccess: Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return true
        case .notDetermined, .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private struct ContactPage {
        let contacts: [CNContact]
        let hasMore: Bool
    }

    /// Contacts exposes a predicate on its incremental fetch request. Using it avoids the old
    /// `unifiedContacts(...).prefix(limit)` pattern, which materialized every name match before the
    /// provider applied its output limit. One extra callback is retained only to disclose `has_more`.
    private func enumerateContacts(
        keys: [CNKeyDescriptor],
        predicate: NSPredicate?,
        limit: Int
    ) throws -> ContactPage {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = predicate
        var contacts: [CNContact] = []
        var hasMore = false
        try store.enumerateContacts(with: request) { contact, stop in
            guard !Task.isCancelled else {
                stop.pointee = true
                return
            }
            contacts.append(contact)
            if contacts.count > limit {
                contacts.removeLast()
                hasMore = true
                stop.pointee = true
            }
        }
        return ContactPage(contacts: contacts, hasMore: hasMore)
    }

    static func makeItem(_ contact: CNContact) -> DataItem {
        // Convert no more than one sentinel value beyond the public entry limit. That preserves the
        // truncation signal without materializing strings for every multi-value property.
        let emails = ProviderOutputBudget.joined(
            contact.emailAddresses.prefix(maximumContactValueEntries + 1).map { String($0.value) },
            maximumEntries: maximumContactValueEntries,
            maximumEntryUTF8Bytes: maximumContactValueUTF8Bytes,
            separator: ", "
        )
        let phones = ProviderOutputBudget.joined(
            contact.phoneNumbers.prefix(maximumContactValueEntries + 1).map { $0.value.stringValue },
            maximumEntries: maximumContactValueEntries,
            maximumEntryUTF8Bytes: maximumContactValueUTF8Bytes,
            separator: ", "
        )
        let identifier = ProviderOutputBudget.text(
            contact.identifier,
            maximumUTF8Bytes: maximumIdentifierUTF8Bytes
        )
        let name = displayName(for: contact)
        let organization = ProviderOutputBudget.text(
            contact.organizationName,
            maximumUTF8Bytes: maximumOrganizationUTF8Bytes
        )
        let jobTitle = ProviderOutputBudget.text(
            contact.jobTitle,
            maximumUTF8Bytes: maximumOrganizationUTF8Bytes
        )
        let preview = [emails.text, phones.text].filter { !$0.isEmpty }.joined(separator: " ")
        let truncated = identifier.truncated || name.truncated || organization.truncated
            || jobTitle.truncated || emails.truncated || phones.truncated

        return DataItem(
            id: identifier.text,
            title: name.text.isEmpty ? "(unnamed contact)" : name.text,
            subtitle: organization.text.isEmpty ? jobTitle.text : organization.text,
            kind: "contact",
            source: "Contacts",
            preview: preview.isEmpty ? nil : preview,
            metadata: [
                "emails": emails.text,
                "phones": phones.text,
                "organization": organization.text,
                "job_title": jobTitle.text,
                "content_truncated": String(truncated)
            ]
        )
    }
}
