    //
    //  DataTypes+Extensions.swift
    //  boringNotch
    //
    //  Created by Harsh Vardhan  Goswami  on 27/08/24.
    //

import Foundation
import BoringCore



extension Date {
    static var yesterday: Date { return Date().dayBefore }
    static var tomorrow:  Date { return Date().dayAfter }
    var dayBefore: Date {
        return Calendar.current.date(byAdding: .day, value: -1, to: noon) ?? self
    }
    var dayAfter: Date {
        return Calendar.current.date(byAdding: .day, value: 1, to: noon) ?? self
    }
    var noon: Date {
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: self) ?? self
    }
    
    var date: String {
        formatted(.dateTime.day(.twoDigits))
    }
    
    var month: String {
        formatted(.dateTime.month(.wide))
    }
    
    func dayOfTheWeek(dayOfWeek: Int) -> String {
        let date = Calendar.current.date(bySetting: .weekday, value: dayOfWeek, of: self) ?? self
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}

extension NSSize {
    var s: String { "\(width.i)×\(height.i)" }
    
    var aspectRatio: Double {
        guard width.isFinite, height.isFinite, height > 0 else { return 0 }
        return width / height
    }
    func scaled(by factor: Double) -> CGSize {
        guard factor.isFinite, factor >= 0, width.isFinite, height.isFinite else { return .zero }
        return CGSize(width: max(0, (width * factor).evenInt), height: max(0, (height * factor).evenInt))
    }
    
}

extension Int {
    var s: String {
        String(self)
    }
    var d: Double {
        Double(self)
    }
}

extension Double {
    @inline(__always) @inlinable var intround: Int {
        rounded().i
    }
    
    @inline(__always) @inlinable var i: Int {
        FiniteNumericConversion.integer(Double(self))
    }
    
    var evenInt: Int {
        FiniteNumericConversion.evenInteger(Double(self))
    }
}

extension CGFloat {
    @inline(__always) @inlinable var intround: Int {
        rounded().i
    }
    
    @inline(__always) @inlinable var i: Int {
        FiniteNumericConversion.integer(Double(self))
    }
    
    var evenInt: Int {
        FiniteNumericConversion.evenInteger(Double(self))
    }
}
