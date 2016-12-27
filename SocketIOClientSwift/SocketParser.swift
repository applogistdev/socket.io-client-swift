//
//  SocketParser.swift
//  Socket.IO-Client-Swift
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

class SocketParser {
    
    fileprivate static func isCorrectNamespace(_ nsp: String, _ socket: SocketIOClient) -> Bool {
        return nsp == socket.nsp
    }

    fileprivate static func handleConnect(_ p: SocketPacket, socket: SocketIOClient) {
        if p.nsp == "/" && socket.nsp != "/" {
            socket.joinNamespace()
        } else if p.nsp != "/" && socket.nsp == "/" {
            socket.didConnect()
        } else {
            socket.didConnect()
        }
    }
    
    fileprivate static func handlePacket(_ pack: SocketPacket, withSocket socket: SocketIOClient) {
        switch pack.type {
        case .event where isCorrectNamespace(pack.nsp, socket):
            socket.handleEvent(pack.event, data: pack.args ?? [],
                isInternalMessage: false, wantsAck: pack.id)
        case .ack where isCorrectNamespace(pack.nsp, socket):
            socket.handleAck(pack.id, data: pack.data as AnyObject?)
        case .binaryEvent where isCorrectNamespace(pack.nsp, socket):
            socket.waitingData.append(pack)
        case .binaryAck where isCorrectNamespace(pack.nsp, socket):
            socket.waitingData.append(pack)
        case .connect:
            handleConnect(pack, socket: socket)
        case .disconnect:
            socket.didDisconnect("Got Disconnect")
        case .error:
            socket.didError(pack.data as AnyObject)
        default: break
            Logger.log("Got invalid packet: %@", type: "SocketParser", args: pack.description as AnyObject)
        }
    }
    
    static func parseString(_ message: String) -> Either<String, SocketPacket> {
        var parser = SocketStringReader(message: message)
        
        guard let type = SocketPacket.PacketType(str: parser.read(1)) else {
            return .left("Invalid packet type")
        }
        
        if !parser.hasNext {
            return .right(SocketPacket(type: type, nsp: "/"))
        }
        
        var namespace: String?
        var placeholders = -1
        
        if type == .binaryEvent || type == .binaryAck {
            if let holders = Int(parser.readUntilStringOccurence("-")) {
                placeholders = holders
            } else {
               return .left("Invalid packet")
            }
        }
        
        if parser.currentCharacter == "/" {
            namespace = parser.readUntilStringOccurence(",") 
        }
        
        if !parser.hasNext {
            return .right(SocketPacket(type: type, id: -1,
                nsp: namespace ?? "/", placeholders: placeholders))
        }
        
        var idString = ""
        
        if type == .error {
            parser.advanceIndexBy(-1)
        }
        
        while parser.hasNext && type != .error {
            if let int = Int(parser.read(1)) {
                idString += String(int)
            } else {
                parser.advanceIndexBy(-2)
                break
            }
        }
        
        let d = message[message.index(parser.currentIndex, offsetBy: 1)..<message.endIndex]
        let noPlaceholders = d["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] ~= "\"~~$2\""
        
        switch parseData(noPlaceholders) {
        case .left(let err):
            // If first you don't succeed, try again
            if case let .right(data) = parseData("\([noPlaceholders as AnyObject])") {
                return .right(SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
                    nsp: namespace ?? "/", placeholders: placeholders))
            } else {
                return .left(err)
            }
        case .right(let data):
            return .right(SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
                nsp: namespace ?? "/", placeholders: placeholders))
        }
    }
    
    // Parses data for events
    fileprivate static func parseData(_ data: String) -> Either<String, [AnyObject]> {
        let stringData = data.data(using: String.Encoding.utf8, allowLossyConversion: false)
        do {
            if let arr = try JSONSerialization.jsonObject(with: stringData!,
                options: JSONSerialization.ReadingOptions.mutableContainers) as? [AnyObject] {
                    return .right(arr)
            } else {
                return .left("Expected data array")
            }
        } catch {
            return .left("Error parsing data for packet")
        }
    }
    
    // Parses messages recieved
    static func parseSocketMessage(_ message: String, socket: SocketIOClient) {
        guard !message.isEmpty else { return }
        
        Logger.log("Parsing %@", type: "SocketParser", args: message as AnyObject)
        
        switch parseString(message) {
        case .left(let err):
            Logger.error("\(err): %@", type: "SocketParser", args: message as AnyObject)
        case .right(let pack):
            Logger.log("Decoded packet as: %@", type: "SocketParser", args: pack.description as AnyObject)
            handlePacket(pack, withSocket: socket)
        }
    }
    
    static func parseBinaryData(_ data: Data, socket: SocketIOClient) {
        guard !socket.waitingData.isEmpty else {
            Logger.error("Got data when not remaking packet", type: "SocketParser")
            return
        }
        
        // Should execute event?
        guard socket.waitingData[socket.waitingData.count - 1].addData(data) else {
            return
        }
        
        var packet = socket.waitingData.removeLast()
        packet.fillInPlaceholders()
        
        if packet.type != .binaryAck {
            socket.handleEvent(packet.event, data: packet.args ?? [],
                isInternalMessage: false, wantsAck: packet.id)
        } else {
            socket.handleAck(packet.id, data: packet.args as AnyObject?)
        }
    }
}
