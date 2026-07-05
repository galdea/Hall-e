import Foundation

/// Persisted people directory (people.json). Mirrors AliasStore's shape.
final class PeopleStore: @unchecked Sendable {
    static let shared = PeopleStore()

    private(set) var people: [Person]
    private let lock = NSLock()

    private init() {
        if let data = try? Data(contentsOf: AppPaths.peopleFile),
           let decoded = try? JSONDecoder().decode([Person].self, from: data) {
            people = decoded
        } else {
            people = []
        }
    }

    func reload() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: AppPaths.peopleFile),
           let decoded = try? JSONDecoder().decode([Person].self, from: data) {
            people = decoded
        }
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(people) {
            try? data.write(to: AppPaths.peopleFile, options: [.atomic])
        }
    }

    func update(_ person: Person) {
        lock.lock()
        if let i = people.firstIndex(where: { $0.id == person.id }) { people[i] = person }
        else { people.append(person) }
        lock.unlock()
        save()
    }

    func remove(_ person: Person) {
        lock.lock()
        people.removeAll { $0.id == person.id }
        lock.unlock()
        save()
    }
}
