namespace eval ::hello {
    namespace export greet
    proc greet {name} {
        return "Hello, $name!"
    }
}
package provide hello 1.0
