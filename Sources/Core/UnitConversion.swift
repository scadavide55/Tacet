import Foundation

/// Conversions typed in the command bar, worked out on the spot with no network: "10 km in mi", "70 kg",
/// "21°C to F", "5 ft in cm". With no target unit, the usual other one is used (km and miles, °C and °F, kg and lb).
enum UnitConversion {
    private static let units: [String: Dimension] = [
        "km": UnitLength.kilometers, "kilometer": UnitLength.kilometers, "kilometers": UnitLength.kilometers, "chilometri": UnitLength.kilometers,
        "m": UnitLength.meters, "meter": UnitLength.meters, "meters": UnitLength.meters, "metri": UnitLength.meters, "metres": UnitLength.meters,
        "cm": UnitLength.centimeters, "mm": UnitLength.millimeters,
        "mi": UnitLength.miles, "mile": UnitLength.miles, "miles": UnitLength.miles, "miglia": UnitLength.miles,
        "ft": UnitLength.feet, "feet": UnitLength.feet, "foot": UnitLength.feet, "piedi": UnitLength.feet,
        "in": UnitLength.inches, "inch": UnitLength.inches, "inches": UnitLength.inches, "pollici": UnitLength.inches,
        "yd": UnitLength.yards, "yards": UnitLength.yards,
        "kg": UnitMass.kilograms, "kilo": UnitMass.kilograms, "kilos": UnitMass.kilograms, "chili": UnitMass.kilograms,
        "g": UnitMass.grams, "grams": UnitMass.grams, "grammi": UnitMass.grams,
        "lb": UnitMass.pounds, "lbs": UnitMass.pounds, "pound": UnitMass.pounds, "pounds": UnitMass.pounds, "libbre": UnitMass.pounds,
        "oz": UnitMass.ounces, "ounces": UnitMass.ounces, "once": UnitMass.ounces,
        "c": UnitTemperature.celsius, "°c": UnitTemperature.celsius, "celsius": UnitTemperature.celsius,
        "f": UnitTemperature.fahrenheit, "°f": UnitTemperature.fahrenheit, "fahrenheit": UnitTemperature.fahrenheit,
        "l": UnitVolume.liters, "liter": UnitVolume.liters, "liters": UnitVolume.liters, "litri": UnitVolume.liters,
        "gal": UnitVolume.gallons, "gallon": UnitVolume.gallons, "gallons": UnitVolume.gallons,
        "km/h": UnitSpeed.kilometersPerHour, "kmh": UnitSpeed.kilometersPerHour, "mph": UnitSpeed.milesPerHour,
    ]

    private static let usual: [Dimension: Dimension] = [
        UnitLength.kilometers: UnitLength.miles, UnitLength.miles: UnitLength.kilometers,
        UnitLength.meters: UnitLength.feet, UnitLength.feet: UnitLength.meters,
        UnitLength.centimeters: UnitLength.inches, UnitLength.inches: UnitLength.centimeters,
        UnitMass.kilograms: UnitMass.pounds, UnitMass.pounds: UnitMass.kilograms,
        UnitMass.grams: UnitMass.ounces, UnitMass.ounces: UnitMass.grams,
        UnitTemperature.celsius: UnitTemperature.fahrenheit, UnitTemperature.fahrenheit: UnitTemperature.celsius,
        UnitVolume.liters: UnitVolume.gallons, UnitVolume.gallons: UnitVolume.liters,
        UnitSpeed.kilometersPerHour: UnitSpeed.milesPerHour, UnitSpeed.milesPerHour: UnitSpeed.kilometersPerHour,
    ]

    /// The converted value and its unit's symbol, or nil when the text isn't a conversion.
    static func convert(_ text: String) -> (value: Double, symbol: String)? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard t.count <= 40, let first = t.first, first.isNumber || first == "-" || first == "." else { return nil }
        let number = t.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let value = Double(number) else { return nil }
        let words = t.dropFirst(number.count).split(separator: " ").map(String.init).filter { !["in", "to", "a", "en", "into"].contains($0) }
        // "in" is both a word and inches: "5 in in cm" and "5 in" read as inches; "10 km in mi" reads "in" as the word.
        let raw = t.dropFirst(number.count).split(separator: " ").map(String.init)
        var parts = words
        if raw.first == "in" { parts = ["in"] + raw.dropFirst().filter { !["in", "to", "a", "en", "into"].contains($0) } }
        guard let fromWord = parts.first, let from = units[fromWord], parts.count <= 2 else { return nil }
        let to: Dimension
        if parts.count == 2 {
            guard let target = units[parts[1]], type(of: target) == type(of: from), target != from else { return nil }
            to = target
        } else {
            guard let target = usual[from] else { return nil }
            to = target
        }
        let result = Measurement(value: value, unit: from).converted(to: to).value
        guard result.isFinite else { return nil }
        return (result, to.symbol)
    }

    static func format(_ c: (value: Double, symbol: String)) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(c.value) < 10 ? 3 : 2
        return (f.string(from: NSNumber(value: c.value)) ?? String(c.value)) + " " + c.symbol
    }
}

extension InlineCompletion {
    /// Whether two addresses are the same page, give or take https, www., a final slash and the part after #.
    static func sameAddress(_ a: URL?, _ b: URL?) -> Bool {
        func key(_ u: URL?) -> String? {
            guard let u, var host = u.host?.lowercased() else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            var path = u.path
            while path.hasSuffix("/") { path.removeLast() }
            return host + path + (u.query.map { "?" + $0 } ?? "")
        }
        guard let ka = key(a), let kb = key(b) else { return false }
        return ka == kb
    }
}
