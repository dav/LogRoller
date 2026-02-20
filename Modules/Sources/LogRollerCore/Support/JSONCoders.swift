import Foundation

public enum LogRollerJSONCoders {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = parse(dateString: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
            }
            return date
        }
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { value, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(render(date: value))
        }
        return encoder
    }()

    public static func parse(dateString: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = fractionalFormatter.date(from: dateString) {
            return date
        }

        let basicFormatter = ISO8601DateFormatter()
        basicFormatter.formatOptions = [.withInternetDateTime]
        basicFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        return basicFormatter.date(from: dateString)
    }

    public static func render(date: Date) -> String {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        return fractionalFormatter.string(from: date)
    }
}
