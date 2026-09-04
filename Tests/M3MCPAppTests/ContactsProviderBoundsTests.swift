import Contacts
import M3MCPCore
import XCTest
@testable import M3MCPApp

final class ContactsProviderBoundsTests: XCTestCase {
    func testOversizedQueryFailsBeforeContactsAuthorizationBoundary() async {
        let response = await ContactsProvider().search(input: [
            "query": .string(String(repeating: "q", count: ContactsProvider.maximumQueryUTF8Bytes + 1))
        ])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("work limit") == true)
    }

    func testContactFieldsAndValueCountsAreBoundedBelowTransportCeiling() throws {
        let contact = CNMutableContact()
        let hostile = String(repeating: "\u{0001}", count: 8_000)
        contact.givenName = hostile
        contact.familyName = hostile
        contact.organizationName = hostile
        contact.jobTitle = hostile
        contact.emailAddresses = (0..<32).map { index in
            CNLabeledValue(label: "mail-\(index)", value: NSString(string: hostile))
        }
        contact.phoneNumbers = (0..<32).map { index in
            CNLabeledValue(label: "phone-\(index)", value: CNPhoneNumber(stringValue: hostile))
        }

        let item = ContactsProvider.makeItem(contact)
        let response = ToolResponse(
            ok: true,
            source: "Contacts",
            items: Array(repeating: item, count: 100)
        )
        let encoded = try M3JSON.makeEncoder().encode(response)

        XCTAssertEqual(item.metadata["content_truncated"], "true")
        XCTAssertLessThanOrEqual(item.title.utf8.count, ContactsProvider.maximumNameUTF8Bytes)
        XCTAssertLessThanOrEqual(
            item.metadata["organization"]?.utf8.count ?? .max,
            ContactsProvider.maximumOrganizationUTF8Bytes
        )
        XCTAssertLessThan(encoded.count, LocalHTTPResponseParser.maximumBodyBytes)
    }
}
