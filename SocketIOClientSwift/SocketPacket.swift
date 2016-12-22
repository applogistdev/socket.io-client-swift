//
//  SocketPacket.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 1/18/15.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation

struct SocketPacket {
    private let placeholders: Int
    private var currentPlace = 0

	private static let logType = "SocketPacket"

    let nsp: String
    let id: Int
    let type: PacketType
    
    enum PacketType: Int {
        case Connect, Disconnect, Event, Ack, Error, BinaryEvent, BinaryAck
        
        init?(str: String) {
            if let int = Int(str), let raw = PacketType(rawValue: int) {
                self = raw
            } else {
                return nil
            }
        }
    }
    
    var args: [AnyObject]? {
        var arr = data
        
        if data.count == 0 {
            return nil
        } else {
            if type == PacketType.Event || type == PacketType.BinaryEvent {
                arr.remove(at: 0)
                return arr
            } else {
                return arr
            }
        }
    }
    
    var binary: [NSData]
    var data: [AnyObject]
    var description: String {
        return "SocketPacket {type: \(String(type.rawValue)); data: " +
            "\(String(describing: data)); id: \(id); placeholders: \(placeholders); nsp: \(nsp)}"
    }
    
    var event: String {
        return data[0] as? String ?? String(describing: data[0])
    }
    
    var packetString: String {
        return createPacketString()
    }
    
    init(type: SocketPacket.PacketType, data: [AnyObject] = [AnyObject](), id: Int = -1,
        nsp: String, placeholders: Int = 0, binary: [NSData] = [NSData]()) {
        self.data = data
        self.id = id
        self.nsp = nsp
        self.type = type
        self.placeholders = placeholders
        self.binary = binary
    }
    
    mutating func addData(data: NSData) -> Bool {
        if placeholders == currentPlace {
            return true
        }
        
        binary.append(data)
        currentPlace += 1
        
        if placeholders == currentPlace {
            currentPlace = 0
            return true
        } else {
            return false
        }
    }
    
    private func completeMessage(message: String, ack: Bool) -> String {
        if data.count == 0 {
            return message + "]"
        }
        var msg = message
        for arg in data {
            if arg is NSDictionary || arg is [AnyObject] {
                do {
                    let jsonSend = try JSONSerialization.data(withJSONObject: arg,options: JSONSerialization.WritingOptions(rawValue: 0))
                    let jsonString = String(data: jsonSend, encoding: .utf8)
                    
                    msg += jsonString! as String + ","
                } catch {
                    Logger.error(message: "Error creating JSON object in SocketPacket.completeMessage", type: SocketPacket.logType)
                }
            } else if var str = arg as? String {
                str = str["\n"] ~= "\\\\n"
                str = str["\r"] ~= "\\\\r"
                
                msg += "\"\(str)\","
            } else if arg is NSNull {
                msg += "null,"
            } else {
                msg += "\(arg),"
            }
        }
        
        if msg != "" {
            msg.remove(at: msg.index(before: msg.endIndex))
        }
        
        return msg + "]"
    }
    
    private func createAck() -> String {
        let msg: String
        
        if type == PacketType.Ack {
            if nsp == "/" {
                msg = "3\(id)["
            } else {
                msg = "3\(nsp),\(id)["
            }
        } else {
            if nsp == "/" {
                msg = "6\(binary.count)-\(id)["
            } else {
                msg = "6\(binary.count)-/\(nsp),\(id)["
            }
        }
        
        return completeMessage(message: msg, ack: true)
    }

    
    private func createMessageForEvent() -> String {
        let message: String
        
        if type == PacketType.Event {
            if nsp == "/" {
                if id == -1 {
                    message = "2["
                } else {
                    message = "2\(id)["
                }
            } else {
                if id == -1 {
                    message = "2\(nsp),["
                } else {
                    message = "2\(nsp),\(id)["
                }
            }
        } else {
            if nsp == "/" {
                if id == -1 {
                    message = "5\(binary.count)-["
                } else {
                    message = "5\(binary.count)-\(id)["
                }
            } else {
                if id == -1 {
                    message = "5\(binary.count)-\(nsp),["
                } else {
                    message = "5\(binary.count)-\(nsp),\(id)["
                }
            }
        }
        
        return completeMessage(message: message, ack: false)
    }
    
    private func createPacketString() -> String {
        let str: String
        
        if type == PacketType.Event || type == PacketType.BinaryEvent {
            str = createMessageForEvent()
        } else {
            str = createAck()
        }
        
        return str
    }
    
    mutating func fillInPlaceholders() {
        for i in 0..<data.count {
            if let str = data[i] as? String, let num = str["~~(\\d)"].groups() {
                data[i] = binary[Int(num[1])!]
            } else if data[i] is NSDictionary || data[i] is NSArray {
                data[i] = _fillInPlaceholders(data: data[i])
            }
        }
    }
    
    private mutating func _fillInPlaceholders(data: AnyObject) -> AnyObject {
        if let str = data as? String {
            if let num = str["~~(\\d)"].groups() {
                return binary[Int(num[1])!]
            } else {
                return str as AnyObject
            }
        } else if let dict = data as? NSDictionary {
            let newDict = NSMutableDictionary(dictionary: dict)
            
            for (key, value) in dict {
                newDict[key as! NSCopying] = _fillInPlaceholders(data: value as AnyObject)
            }
            
            return newDict
        } else if let arr = data as? NSArray {
            let newArr = NSMutableArray(array: arr)
            
            for i in 0..<arr.count {
                newArr[i] = _fillInPlaceholders(data: arr[i] as AnyObject)
            }
            
            return newArr
        } else {
            return data
        }
    }
}

extension SocketPacket {
    private static func findType(binCount: Int, ack: Bool) -> PacketType {
        switch binCount {
        case 0 where !ack:
            return PacketType.Event
        case 0 where ack:
            return PacketType.Ack
        case _ where !ack:
            return PacketType.BinaryEvent
        case _ where ack:
            return PacketType.BinaryAck
        default:
            return PacketType.Error
        }
    }
    
    static func packetFromEmit(items: [AnyObject], id: Int, nsp: String, ack: Bool) -> SocketPacket {
        let (parsedData, binary) = deconstructData(data: items)
        let packet = SocketPacket(type: findType(binCount: binary.count, ack: ack), data: parsedData,
            id: id, nsp: nsp, placeholders: -1, binary: binary)
        
        return packet
    }
}

private extension SocketPacket {
    static func shred(data: AnyObject, binary: inout [NSData]) -> AnyObject {
        if let bin = data as? NSData {
            let placeholder = ["_placeholder" :true, "num": binary.count] as [String : Any]
            
            binary.append(bin)
            
            return placeholder as AnyObject
        } else if var arr = data as? [AnyObject] {
            for i in 0 ..< arr.count {
                arr[i] = shred(data: arr[i], binary: &binary)
            }
            
            return arr as AnyObject
        } else if let dict = data as? NSDictionary {
            let mutDict = NSMutableDictionary(dictionary: dict)
            
            for (key, value) in dict {
                mutDict[key as! NSCopying] = shred(data: value as AnyObject, binary: &binary)
            }
            
            return mutDict
        } else {
            return data
        }
    }
    
    static func deconstructData(data: [AnyObject]) -> ([AnyObject], [NSData]) {
        var binary = [NSData]()
        var handledData = data
        for i in 0 ..< handledData.count {
            if handledData[i] is NSArray || handledData[i] is NSDictionary {
                handledData[i] = shred(data: handledData[i], binary: &binary)
            } else if let bin = data[i] as? NSData {
                handledData[i] = ["_placeholder" :true, "num": binary.count] as AnyObject
                binary.append(bin)
            }
        }
        
        return (handledData, binary)
    }
}
