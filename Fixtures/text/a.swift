import Foundation

struct Greeter {
    let name: String

    func greet() -> String {
        "Hello, \(name)!"
    }

    func farewell() -> String {
        "Goodbye, \(name)."
    }
}

let g = Greeter(name: "World")
print(g.greet())
print(g.farewell())
