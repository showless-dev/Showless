import Foundation

public enum ShellQuoting {
    public static func quote(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }

        let special = CharacterSet(charactersIn: " \t\n\"'\\|&;()<>$`!{}[]*?#~")
        if value.rangeOfCharacter(from: special) == nil {
            return value
        }

        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
