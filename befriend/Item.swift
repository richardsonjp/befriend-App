//
//  Item.swift
//  befriend
//
//  Created by Richardson Jayaputra on 10/09/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
