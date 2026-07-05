import Foundation

/// A person the user knows, assigned to one or more projects. Their emails let
/// meetings classify by attendee; their name (matched in a call transcript)
/// nudges a call toward their project. Phones are stored as contact data.
struct Person: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var emails: [String]
    var phones: [String]
    var projectIds: [String]
    var notes: String?
    var isArchived: Bool

    init(id: String = UUID().uuidString, name: String, emails: [String] = [],
         phones: [String] = [], projectIds: [String] = [], notes: String? = nil,
         isArchived: Bool = false) {
        self.id = id; self.name = name; self.emails = emails; self.phones = phones
        self.projectIds = projectIds; self.notes = notes; self.isArchived = isArchived
    }
}
