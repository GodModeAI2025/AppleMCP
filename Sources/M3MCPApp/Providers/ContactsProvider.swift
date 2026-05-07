import AppKit
import Contacts
import Foundation
import M3MCPCore

final class ContactsProvider {
    private let store = CNContactStore()

    func search(input: [String: JSONValue]) async -> ToolResponse {
        do {
            let granted = try await requestAccess()
            guard granted else {
                return ToolResponse(ok: false, source: "Contacts", message: "Contacts access was not granted.")
            }

            let query = input.string("query")
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

            let contacts: [CNContact]
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contacts = try enumerateContacts(keys: keys, limit: limit)
            } else {
                contacts = try store.unifiedContacts(
                    matching: CNContact.predicateForContacts(matchingName: query),
                    keysToFetch: keys
                )
                .prefix(limit)
                .map { $0 }
            }

            let items = contacts.map { contact in
                let emails = contact.emailAddresses.map { String($0.value) }
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                let name = displayName(for: contact)

                return DataItem(
                    id: contact.identifier,
                    title: name.isEmpty ? "(unnamed contact)" : name,
                    subtitle: contact.organizationName.isEmpty ? contact.jobTitle : contact.organizationName,
                    kind: "contact",
                    source: "Contacts",
                    preview: (emails + phones).joined(separator: " "),
                    metadata: [
                        "emails": emails.joined(separator: ", "),
                        "phones": phones.joined(separator: ", "),
                        "organization": contact.organizationName,
                        "job_title": contact.jobTitle
                    ]
                )
            }

            return ToolResponse(ok: true, source: "Contacts", items: items)
        } catch {
            return ToolResponse(ok: false, source: "Contacts", message: error.localizedDescription)
        }
    }

    private func displayName(for contact: CNContact) -> String {
        let components = [
            contact.givenName,
            contact.familyName
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        if !components.isEmpty {
            return components.joined(separator: " ")
        }

        return contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func requestAccess() async throws -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized {
            return true
        }

        let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
        return granted
    }

    private func enumerateContacts(keys: [CNKeyDescriptor], limit: Int) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, stop in
            contacts.append(contact)
            if contacts.count >= limit {
                stop.pointee = true
            }
        }
        return contacts
    }
}
