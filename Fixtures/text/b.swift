import Foundation

/// Says hello and goodbye.
struct Greeter {
    let name: String
    var excited = false

    func greet() -> String {
        excited ? "Hello, \(name)!!!" : "Hello, \(name)!"
    }

    func farewell() -> String {
        "Goodbye, \(name)."
    }
}

let g = Greeter(name: "Delta")
print(g.greet())
