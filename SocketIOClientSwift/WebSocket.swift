//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Websocket.swift
//
//  Created by Dalton Cherry on 7/16/14.
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
import CoreFoundation
import Security

public protocol WebSocketDelegate: class {
    func websocketDidConnect(socket: WebSocket)
    func websocketDidDisconnect(socket: WebSocket, error: NSError?)
    func websocketDidReceiveMessage(socket: WebSocket, text: String)
    func websocketDidReceiveData(socket: WebSocket, data: NSData)
}

public protocol WebSocketPongDelegate: class {
    func websocketDidReceivePong(socket: WebSocket)
}

public class WebSocket : NSObject, StreamDelegate {
    
    enum OpCode : UInt8 {
        case ContinueFrame = 0x0
        case TextFrame = 0x1
        case BinaryFrame = 0x2
        //3-7 are reserved.
        case ConnectionClose = 0x8
        case Ping = 0x9
        case Pong = 0xA
        //B-F reserved.
    }
    
    enum CloseCode : UInt16 {
        case Normal                 = 1000
        case GoingAway              = 1001
        case ProtocolError          = 1002
        case ProtocolUnhandledType  = 1003
        // 1004 reserved.
        case NoStatusReceived       = 1005
        //1006 reserved.
        case Encoding               = 1007
        case PolicyViolated         = 1008
        case MessageTooBig          = 1009
    }
    
    enum InternalErrorCode : UInt16 {
        // 0-999 WebSocket status codes not used
        case OutputStreamWriteError  = 1
    }
    
    //Where the callback is executed. It defaults to the main UI thread queue.
    public var queue            = DispatchQueue.main
    
    var optionalProtocols       : Array<String>?
    //Constant Values.
    let headerWSUpgradeName     = "Upgrade"
    let headerWSUpgradeValue    = "websocket"
    let headerWSHostName        = "Host"
    let headerWSConnectionName  = "Connection"
    let headerWSConnectionValue = "Upgrade"
    let headerWSProtocolName    = "Sec-WebSocket-Protocol"
    let headerWSVersionName     = "Sec-WebSocket-Version"
    let headerWSVersionValue    = "13"
    let headerWSKeyName         = "Sec-WebSocket-Key"
    let headerOriginName        = "Origin"
    let headerWSAcceptName      = "Sec-WebSocket-Accept"
    let BUFFER_MAX              = 4096
    let FinMask: UInt8          = 0x80
    let OpCodeMask: UInt8       = 0x0F
    let RSVMask: UInt8          = 0x70
    let MaskMask: UInt8         = 0x80
    let PayloadLenMask: UInt8   = 0x7F
    let MaxFrameSize: Int       = 32
    
    class WSResponse {
        var isFin = false
        var code: OpCode = .ContinueFrame
        var bytesLeft = 0
        var frameCount = 0
        var buffer: NSMutableData?
    }
    
    public weak var delegate: WebSocketDelegate?
    public weak var pongDelegate: WebSocketPongDelegate?
    public var onConnect: ((Void) -> Void)?
    public var onDisconnect: ((NSError?) -> Void)?
    public var onText: ((String) -> Void)?
    public var onData: ((NSData) -> Void)?
    public var onPong: ((Void) -> Void)?
    public var headers = Dictionary<String,String>()
    public var voipEnabled = false
    public var selfSignedSSL = false
    private var security: SSLSecurity?
    public var enabledSSLCipherSuites: [SSLCipherSuite]?
    public var isConnected :Bool {
        return connected
    }
    private var url: NSURL
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var isRunLoop = false
    private var connected = false
    private var isCreated = false
    private var writeQueue = OperationQueue()
    private var readStack = Array<WSResponse>()
    private var inputQueue = Array<NSData>()
    private var fragBuffer: NSData?
    private var certValidated = false
    private var didDisconnect = false
    
    //init the websocket with a url
    public init(url: NSURL) {
        self.url = url
        writeQueue.maxConcurrentOperationCount = 1
    }
    //used for setting protocols.
    public convenience init(url: NSURL, protocols: Array<String>) {
        self.init(url: url)
        optionalProtocols = protocols
    }
    
    ///Connect to the websocket server on a background thread
    public func connect() {
        if isCreated {
            return
        }
        queue.async(execute: { [weak self] in
            self?.didDisconnect = false
            })
        DispatchQueue.global().async {
            self.isCreated = true
            self.createHTTPRequest()
            self.isCreated = false
        }
    }
    
    ///disconnect from the websocket server
    public func disconnect() {
        writeError(code: CloseCode.Normal.rawValue)
    }
    
    ///write a string to the websocket. This sends it as a text frame.
    public func writeString(str: String) {
        dequeueWrite(data: str.data(using: String.Encoding.utf8)!, code: .TextFrame)
    }
    
    ///write binary data to the websocket. This sends it as a binary frame.
    public func writeData(data: Data) {
        dequeueWrite(data: data, code: .BinaryFrame)
    }
    
    //write a   ping   to the websocket. This sends it as a  control frame.
    //yodel a   sound  to the planet.    This sends it as an astroid. http://youtu.be/Eu5ZJELRiJ8?t=42s
    public func writePing(data: Data) {
        dequeueWrite(data: data, code: .Ping)
    }
    //private methods below!
    
    //private method that starts the connection
    private func createHTTPRequest() {
        
        let urlRequest = CFHTTPMessageCreateRequest(kCFAllocatorDefault, "GET" as CFString, url, kCFHTTPVersion1_1).takeRetainedValue()
        
        var port = url.port
        if port == nil {
            if url.scheme == "wss" || url.scheme == "https" {
                port = 443
            } else {
                port = 80
            }
        }
        addHeader(urlRequest: urlRequest, key: headerWSUpgradeName, val: headerWSUpgradeValue)
        addHeader(urlRequest: urlRequest, key: headerWSConnectionName, val: headerWSConnectionValue)
        if let protocols = optionalProtocols {
            addHeader(urlRequest: urlRequest, key: headerWSProtocolName, val: protocols.joined(separator: ","))
        }
        addHeader(urlRequest: urlRequest, key: headerWSVersionName, val: headerWSVersionValue)
        addHeader(urlRequest: urlRequest, key: headerWSKeyName, val: generateWebSocketKey())
        addHeader(urlRequest: urlRequest, key: headerOriginName, val: url.absoluteString!)
        addHeader(urlRequest: urlRequest, key: headerWSHostName, val: "\(url.host!):\(port!)")
        for (key,value) in headers {
            addHeader(urlRequest: urlRequest, key: key, val: value)
        }
        if let cfHTTPMessage = CFHTTPMessageCopySerializedMessage(urlRequest) {
            let serializedRequest = cfHTTPMessage.takeRetainedValue()
            initStreamsWithData(data:serializedRequest, Int(port!))
        }
    }
    //Add a header to the CFHTTPMessage by using the NSString bridges to CFString
    private func addHeader(urlRequest: CFHTTPMessage,key: String, val: String) {
        let nsKey: NSString = key as NSString
        let nsVal: NSString = val as NSString
        CFHTTPMessageSetHeaderFieldValue(urlRequest,nsKey,nsVal)
    }
    //generate a websocket key as needed in rfc
    private func generateWebSocketKey() -> String {
        var key = ""
        let seed = 16
        for _ in 0 ..< seed {
            let uni = UnicodeScalar(UInt32(97 + arc4random_uniform(25)))
            key += "\(Character(uni!))"
        }
        let data = key.data(using: String.Encoding.utf8)
        let baseKey = data?.base64EncodedString(options: Data.Base64EncodingOptions(rawValue: 0))
        return baseKey!
    }
    //Start the stream connection and write the data to the output stream
    private func initStreamsWithData(data: NSData, _ port: Int) {
        //higher level API we will cut over to at some point
        //NSStream.getStreamsToHostWithName(url.host, port: url.port.integerValue, inputStream: &inputStream, outputStream: &outputStream)
        
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        let h: String = url.host!
        CFStreamCreatePairWithSocketToHost(nil, h as CFString!, UInt32(port), &readStream, &writeStream)
        inputStream = readStream!.takeRetainedValue()
        outputStream = writeStream!.takeRetainedValue()
        guard let inStream = inputStream, let outStream = outputStream else { return }
        inStream.delegate = self
        outStream.delegate = self
        if url.scheme == "wss" || url.scheme == "https" {
            inStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: Stream.PropertyKey.socketSecurityLevelKey)
            outStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: Stream.PropertyKey.socketSecurityLevelKey)
        } else {
            certValidated = true //not a https session, so no need to check SSL pinning
        }
        if voipEnabled {
            inStream.setProperty(StreamNetworkServiceTypeValue.voIP, forKey: Stream.PropertyKey.networkServiceType)
            outStream.setProperty(StreamNetworkServiceTypeValue.voIP, forKey: Stream.PropertyKey.networkServiceType)
        }
        if selfSignedSSL {
            let settings: Dictionary<NSObject, NSObject> = [kCFStreamSSLValidatesCertificateChain: NSNumber(value:false), kCFStreamSSLPeerName: kCFNull]
            inStream.setProperty(settings, forKey: Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String))
            outStream.setProperty(settings, forKey: Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String))
        }
        if let cipherSuites = self.enabledSSLCipherSuites {
            if let sslContextIn = CFReadStreamCopyProperty(inputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLContext)) as! SSLContext?,
                let sslContextOut = CFWriteStreamCopyProperty(outputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLContext)) as! SSLContext? {
                    let resIn = SSLSetEnabledCiphers(sslContextIn, cipherSuites, cipherSuites.count)
                    let resOut = SSLSetEnabledCiphers(sslContextOut, cipherSuites, cipherSuites.count)
                    if (resIn != errSecSuccess) {
                        let error = self.errorWithDetail(detail: "Error setting ingoing cypher suites", code: UInt16(resIn))
                        disconnectStream(error: error)
                        return
                    }
                    if (resOut != errSecSuccess) {
                        let error = self.errorWithDetail(detail: "Error setting outgoing cypher suites", code: UInt16(resOut))
                        disconnectStream(error: error)
                        return
                    }
            }
        }
        isRunLoop = true
        inStream.schedule(in: RunLoop.current, forMode: .defaultRunLoopMode)
        outStream.schedule(in: RunLoop.current, forMode:                              .defaultRunLoopMode)
        inStream.open()
        outStream.open()
        let bytes = UnsafePointer<UInt8>(data.bytes)
        outStream.write(bytes, maxLength: data.length)
        while(isRunLoop) {
            RunLoop.current.run(mode: .defaultRunLoopMode, before: .distantFuture)
        }
    }
    //delegate for the stream methods. Processes incoming bytes
    public func stream(aStream: Stream, handleEvent eventCode: Stream.Event) {
        
        if let sec = security, !certValidated && (eventCode == .hasBytesAvailable || eventCode == .hasSpaceAvailable) {
            let possibleTrust: AnyObject? = aStream.property(forKey: Stream.PropertyKey(rawValue: kCFStreamPropertySSLPeerTrust as String)) as AnyObject?

            if let trust: AnyObject = possibleTrust {
                let domain: AnyObject? = aStream.property(forKey: Stream.PropertyKey(rawValue: kCFStreamSSLPeerName as String)) as AnyObject?
                if sec.isValid(trust as! SecTrust, domain: domain as! String?) {
                    certValidated = true
                } else {
                    let error = errorWithDetail(detail: "Invalid SSL certificate", code: 1)
                    disconnectStream(error: error)
                    return
                }
            }
        }
        if eventCode == .hasBytesAvailable {
            if(aStream == inputStream) {
                processInputStream()
            }
        } else if eventCode == .errorOccurred {
            disconnectStream(error: aStream.streamError)
        } else if eventCode == .endEncountered {
            disconnectStream(error: nil)
        }
    }
    //disconnect the stream object
    private func disconnectStream(error: Error?) {
        writeQueue.waitUntilAllOperationsAreFinished()
        if let stream = inputStream {
            stream.remove(from: RunLoop.current, forMode: .defaultRunLoopMode)
            stream.close()
        }
        if let stream = outputStream {
            stream.remove(from: RunLoop.current, forMode: .defaultRunLoopMode)
            stream.close()
        }
        outputStream = nil
        isRunLoop = false
        certValidated = false
        doDisconnect(error: error)
        connected = false
    }
    
    ///handles the incoming bytes and sending them to the proper processing method
    private func processInputStream() {
        let buf = NSMutableData(capacity: BUFFER_MAX)
        let buffer = UnsafeMutablePointer<UInt8>(buf!.bytes)
        let length = inputStream!.read(buffer, maxLength: BUFFER_MAX)
        if length > 0 {
            if !connected {
                connected = processHTTP(buffer, bufferLen: length)
                if !connected {
                    let response = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, false).takeRetainedValue()
                    CFHTTPMessageAppendBytes(response, buffer, length)
                    let code = CFHTTPMessageGetResponseStatusCode(response)
                    doDisconnect(error: errorWithDetail(detail: "Invalid HTTP upgrade", code: UInt16(code)))
                }
            } else {
                var process = false
                if inputQueue.count == 0 {
                    process = true
                }
                inputQueue.append(NSData(bytes: buffer, length: length))
                if process {
                    dequeueInput()
                }
            }
        }
    }
    ///dequeue the incoming input so it is processed in order
    private func dequeueInput() {
        if inputQueue.count > 0 {
            let data = inputQueue[0]
            var work = data
            if fragBuffer != nil {
                let combine = NSMutableData(data: fragBuffer! as Data)
                combine.append(data as Data)
                work = combine
                fragBuffer = nil
            }
            let buffer = UnsafePointer<UInt8>(work.bytes)
            processRawMessage(buffer, bufferLen: work.length)
            inputQueue = inputQueue.filter{$0 != data}
            dequeueInput()
        }
    }
    ///Finds the HTTP Packet in the TCP stream, by looking for the CRLF.
    private func processHTTP(buffer: UnsafePointer<UInt8>, bufferLen: Int) -> Bool {
        let CRLFBytes = [UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\n")]
        var k = 0
        var totalSize = 0
        for i in 0 ..< bufferLen {
            if buffer[i] == CRLFBytes[k] {
                k += 1
                if k == 3 {
                    totalSize = i + 1
                    break
                }
            } else {
                k = 0
            }
        }
        if totalSize > 0 {
            if validateResponse(buffer: buffer, bufferLen: totalSize) {
                queue.async(execute: { [weak self] in
                    guard let s = self else { return }
                    if let connectBlock = s.onConnect {
                        connectBlock()
                    }
                    s.delegate?.websocketDidConnect(socket: s)
                })
//                dispatch_async(queue,{ [weak self] in
//                    guard let s = self else { return }
//                    if let connectBlock = s.onConnect {
//                        connectBlock()
//                    }
//                    s.delegate?.websocketDidConnect(s)
//                    })
                totalSize += 1 //skip the last \n
                let restSize = bufferLen - totalSize
                if restSize > 0 {
                    processRawMessage(buffer: (buffer+totalSize),bufferLen: restSize)
                }
                return true
            }
        }
        return false
    }
    
    ///validates the HTTP is a 101 as per the RFC spec
    private func validateResponse(buffer: UnsafePointer<UInt8>, bufferLen: Int) -> Bool {
        let response = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, false).takeRetainedValue()
        CFHTTPMessageAppendBytes(response, buffer, bufferLen)
        if CFHTTPMessageGetResponseStatusCode(response) != 101 {
            return false
        }
        if let cfHeaders = CFHTTPMessageCopyAllHeaderFields(response) {
            let headers = cfHeaders.takeRetainedValue() as NSDictionary
            let acceptKey = headers[headerWSAcceptName] as! NSString
            if acceptKey.length > 0 {
                return true
            }
        }
        return false
    }
    
    ///process the websocket data
    private func processRawMessage(buffer: UnsafePointer<UInt8>, bufferLen: Int) {
        let response = readStack.last
        if response != nil && bufferLen < 2  {
            fragBuffer = NSData(bytes: buffer, length: bufferLen)
            return
        }
        if response != nil && response!.bytesLeft > 0 {
            let resp = response!
            var len = resp.bytesLeft
            var extra = bufferLen - resp.bytesLeft
            if resp.bytesLeft > bufferLen {
                len = bufferLen
                extra = 0
            }
            resp.bytesLeft -= len
            
            resp.buffer?.append(Data(bytes: buffer, count: len))
            _ = processResponse(response: resp)
            let offset = bufferLen - extra
            if extra > 0 {
                processExtra(buffer: (buffer+offset), bufferLen: extra)
            }
            return
        } else {
            let isFin = (FinMask & buffer[0])
            let receivedOpcode = (OpCodeMask & buffer[0])
            let isMasked = (MaskMask & buffer[1])
            let payloadLen = (PayloadLenMask & buffer[1])
            var offset = 2
            if((isMasked > 0 || (RSVMask & buffer[0]) > 0) && receivedOpcode != OpCode.Pong.rawValue) {
                let errCode = CloseCode.ProtocolError.rawValue
                doDisconnect(error: errorWithDetail(detail: "masked and rsv data is not currently supported", code: errCode))
                writeError(code: errCode)
                return
            }
            let isControlFrame = (receivedOpcode == OpCode.ConnectionClose.rawValue || receivedOpcode == OpCode.Ping.rawValue)
            if !isControlFrame && (receivedOpcode != OpCode.BinaryFrame.rawValue && receivedOpcode != OpCode.ContinueFrame.rawValue &&
                receivedOpcode != OpCode.TextFrame.rawValue && receivedOpcode != OpCode.Pong.rawValue) {
                    let errCode = CloseCode.ProtocolError.rawValue
                    doDisconnect(error: errorWithDetail(detail: "unknown opcode: \(receivedOpcode)", code: errCode))
                    writeError(code: errCode)
                    return
            }
            if isControlFrame && isFin == 0 {
                let errCode = CloseCode.ProtocolError.rawValue
                doDisconnect(error: errorWithDetail(detail: "control frames can't be fragmented", code: errCode))
                writeError(code: errCode)
                return
            }
            if receivedOpcode == OpCode.ConnectionClose.rawValue {
                var code = CloseCode.Normal.rawValue
                if payloadLen == 1 {
                    code = CloseCode.ProtocolError.rawValue
                } else if payloadLen > 1 {
                    let codeBuffer = UnsafePointer<UInt16>((buffer+offset))
                    code = codeBuffer[0].bigEndian
                    if code < 1000 || (code > 1003 && code < 1007) || (code > 1011 && code < 3000) {
                        code = CloseCode.ProtocolError.rawValue
                    }
                    offset += 2
                }
                if payloadLen > 2 {
                    let len = Int(payloadLen-2)
                    if len > 0 {
                        let bytes = UnsafePointer<UInt8>((buffer+offset))
                        let str: String? = String(data: Data(bytes: bytes, count: len), encoding: String.Encoding.utf8)
                        if str == nil {
                            code = CloseCode.ProtocolError.rawValue
                        }
                    }
                }
                doDisconnect(error: errorWithDetail(detail: "connection closed by server", code: code))
                writeError(code: code)
                return
            }
            if isControlFrame && payloadLen > 125 {
                writeError(code: CloseCode.ProtocolError.rawValue)
                return
            }
            var dataLength = UInt64(payloadLen)
            if dataLength == 127 {
                let bytes = UnsafePointer<UInt64>((buffer+offset))
                dataLength = bytes[0].bigEndian
                offset += sizeof(UInt64)
            } else if dataLength == 126 {
                let bytes = UnsafePointer<UInt16>((buffer+offset))
                dataLength = UInt64(bytes[0].bigEndian)
                offset += sizeof(UInt16)
            }
            if bufferLen < offset || UInt64(bufferLen - offset) < dataLength {
                fragBuffer = NSData(bytes: buffer, length: bufferLen)
                return
            }
            var len = dataLength
            if dataLength > UInt64(bufferLen) {
                len = UInt64(bufferLen-offset)
            }
            var data: NSData!
            if len < 0 {
                len = 0
                data = NSData()
            } else {
                data = NSData(bytes: UnsafePointer<UInt8>((buffer+offset)), length: Int(len))
            }
            if receivedOpcode == OpCode.Pong.rawValue {
                queue.async(execute: { [weak self] in
                    guard let s = self else { return }
                    if let pongBlock = s.onPong {
                        pongBlock()
                    }
                    s.pongDelegate?.websocketDidReceivePong(socket: s)
                })
                
                let step = Int(offset+numericCast(len))
                let extra = bufferLen-step
                if extra > 0 {
                    processRawMessage(buffer: (buffer+step), bufferLen: extra)
                }
                return
            }
            var response = readStack.last
            if isControlFrame {
                response = nil //don't append pings
            }
            if isFin == 0 && receivedOpcode == OpCode.ContinueFrame.rawValue && response == nil {
                let errCode = CloseCode.ProtocolError.rawValue
                doDisconnect(error: errorWithDetail(detail: "continue frame before a binary or text frame", code: errCode))
                writeError(code: errCode)
                return
            }
            var isNew = false
            if(response == nil) {
                if receivedOpcode == OpCode.ContinueFrame.rawValue  {
                    let errCode = CloseCode.ProtocolError.rawValue
                    doDisconnect(error: errorWithDetail(detail: "first frame can't be a continue frame",
                        code: errCode))
                    writeError(code: errCode)
                    return
                }
                isNew = true
                response = WSResponse()
                response!.code = OpCode(rawValue: receivedOpcode)!
                response!.bytesLeft = Int(dataLength)
                response!.buffer = NSMutableData(data: data as Data)
            } else {
                if receivedOpcode == OpCode.ContinueFrame.rawValue  {
                    response!.bytesLeft = Int(dataLength)
                } else {
                    let errCode = CloseCode.ProtocolError.rawValue
                    doDisconnect(error: errorWithDetail(detail: "second and beyond of fragment message must be a continue frame",code: errCode))
                    writeError(code: errCode)
                    return
                }
                response!.buffer!.append(data as Data)
            }
            if response != nil {
                response!.bytesLeft -= Int(len)
                response!.frameCount += 1
                response!.isFin = isFin > 0 ? true : false
                if(isNew) {
                    readStack.append(response!)
                }
                _ = processResponse(response: response!)
            }
            
            let step = Int(offset+numericCast(len))
            let extra = bufferLen-step
            if(extra > 0) {
                processExtra(buffer: (buffer+step), bufferLen: extra)
            }
        }
        
    }
    
    ///process the extra of a buffer
    private func processExtra(buffer: UnsafePointer<UInt8>, bufferLen: Int) {
        if bufferLen < 2 {
            fragBuffer = NSData(bytes: buffer, length: bufferLen)
        } else {
            processRawMessage(buffer: buffer, bufferLen: bufferLen)
        }
    }
    
    ///process the finished response of a buffer
    private func processResponse(response: WSResponse) -> Bool {
        if response.isFin && response.bytesLeft <= 0 {
            if response.code == .Ping {
                let data = response.buffer! //local copy so it is perverse for writing
                dequeueWrite(data: data as Data, code: OpCode.Pong)
            } else if response.code == .TextFrame {
                let str: String? = String(data: response.buffer! as Data, encoding: String.Encoding.utf8)
                if str == nil {
                    writeError(code: CloseCode.Encoding.rawValue)
                    return false
                }
                queue.async(execute: { [weak self] in
                    guard let s = self else { return }
                    if let textBlock = s.onText {
                        textBlock(str!)
                    }
                    s.delegate?.websocketDidReceiveMessage(socket: s, text: str! as String)
                })
//                dispatch_async(queue,{ [weak self] in
//                    guard let s = self else { return }
//                    if let textBlock = s.onText {
//                        textBlock(str! as String)
//                    }
//                    s.delegate?.websocketDidReceiveMessage(s, text: str! as String)
//                    })
            } else if response.code == .BinaryFrame {
                let data = response.buffer! //local copy so it is perverse for writing
                queue.async(execute: { [weak self] in
                    guard let s = self else { return }
                    if let dataBlock = s.onData {
                        dataBlock(data)
                    }
                    s.delegate?.websocketDidReceiveData(socket: s, data: data)
                })
            }
            readStack.removeLast()
            return true
        }
        return false
    }
    
    ///Create an error
    private func errorWithDetail(detail: String, code: UInt16) -> NSError {
        var details = Dictionary<String,String>()
        details[NSLocalizedDescriptionKey] =  detail
        return NSError(domain: "Websocket", code: Int(code), userInfo: details)
    }
    
    ///write a an error to the socket
    private func writeError(code: UInt16) {
        let buf = NSMutableData(capacity: sizeof(UInt16))
        let buffer = UnsafeMutablePointer<UInt16>(buf!.bytes)
        buffer[0] = code.bigEndian
        dequeueWrite(NSData(bytes: buffer, length: sizeof(UInt16)), code: .ConnectionClose)
    }
    ///used to write things to the stream
    private func dequeueWrite(data: Data, code: OpCode) {
        if !isConnected {
            return
        }
        writeQueue.addOperationWithBlock { [weak self] in
            //stream isn't ready, let's wait
            guard let s = self else { return }
            var offset = 2
            let bytes = UnsafeMutablePointer<UInt8>(data.bytes)
            let dataLength = data.length
            let frame = NSMutableData(capacity: dataLength + s.MaxFrameSize)
            let buffer = UnsafeMutablePointer<UInt8>(frame!.mutableBytes)
            buffer[0] = s.FinMask | code.rawValue
            if dataLength < 126 {
                buffer[1] = CUnsignedChar(dataLength)
            } else if dataLength <= Int(UInt16.max) {
                buffer[1] = 126
                let sizeBuffer = UnsafeMutablePointer<UInt16>((buffer+offset))
                sizeBuffer[0] = UInt16(dataLength).bigEndian
                offset += sizeof(UInt16)
            } else {
                buffer[1] = 127
                let sizeBuffer = UnsafeMutablePointer<UInt64>((buffer+offset))
                sizeBuffer[0] = UInt64(dataLength).bigEndian
                offset += sizeof(UInt64)
            }
            buffer[1] |= s.MaskMask
            let maskKey = UnsafeMutablePointer<UInt8>(buffer + offset)
            _ = SecRandomCopyBytes(kSecRandomDefault, Int(sizeof(UInt32)), maskKey)
            offset += sizeof(UInt32)
            
            for i in 0 ..< dataLength {
                buffer[offset] = bytes[i] ^ maskKey[i % sizeof(UInt32)]
                offset += 1
            }
            var total = 0
            while true {
                if !s.isConnected {
                    break
                }
                guard let outStream = s.outputStream else { break }
                let writeBuffer = UnsafePointer<UInt8>(frame!.bytes+total)
                let len = outStream.write(writeBuffer, maxLength: offset-total)
                if len < 0 {
                    var error: NSError?
                    if let streamError = outStream.streamError {
                        error = streamError
                    } else {
                        let errCode = InternalErrorCode.OutputStreamWriteError.rawValue
                        error = s.errorWithDetail("output stream error during write", code: errCode)
                    }
                    s.doDisconnect(error)
                    break
                } else {
                    total += len
                }
                if total >= offset {
                    break
                }
            }
            
        }
    }
    
    ///used to preform the disconnect delegate
    private func doDisconnect(error: Error?) {
        if !didDisconnect {
            dispatch_async(queue,{ [weak self] in
                guard let s = self else { return }
                s.didDisconnect = true
                if let disconnect = s.onDisconnect {
                    disconnect(error)
                }
                s.delegate?.websocketDidDisconnect(s, error: error)
                })
        }
    }
    
}

private class SSLCert {
    var certData: NSData?
    var key: SecKeyRef?
    
    /**
    Designated init for certificates
    
    - parameter data: is the binary data of the certificate
    
    - returns: a representation security object to be used with
    */
    init(data: NSData) {
        self.certData = data
    }
    
    /**
    Designated init for public keys
    
    - parameter key: is the public key to be used
    
    - returns: a representation security object to be used with
    */
    init(key: SecKeyRef) {
        self.key = key
    }
}

private class SSLSecurity {
    var validatedDN = true //should the domain name be validated?
    
    var isReady = false //is the key processing done?
    var certificates: [NSData]? //the certificates
    var pubKeys: [SecKeyRef]? //the public keys
    var usePublicKeys = false //use public keys or certificate validation?
    
    /**
    Use certs from main app bundle
    
    - parameter usePublicKeys: is to specific if the publicKeys or certificates should be used for SSL pinning validation
    
    - returns: a representation security object to be used with
    */
    convenience init(usePublicKeys: Bool = false) {
        let paths = NSBundle.mainBundle().pathsForResourcesOfType("cer", inDirectory: ".")
        var collect = Array<SSLCert>()
        for path in paths {
            if let d = NSData(contentsOfFile: path as String) {
                collect.append(SSLCert(data: d))
            }
        }
        self.init(certs:collect, usePublicKeys: usePublicKeys)
    }
    
    /**
    Designated init
    
    - parameter keys: is the certificates or public keys to use
    - parameter usePublicKeys: is to specific if the publicKeys or certificates should be used for SSL pinning validation
    
    - returns: a representation security object to be used with
    */
    init(certs: [SSLCert], usePublicKeys: Bool) {
        self.usePublicKeys = usePublicKeys
        
        if self.usePublicKeys {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), {
                var collect = Array<SecKeyRef>()
                for cert in certs {
                    if let data = cert.certData where cert.key == nil  {
                        cert.key = self.extractPublicKey(data)
                    }
                    if let k = cert.key {
                        collect.append(k)
                    }
                }
                self.pubKeys = collect
                self.isReady = true
            })
        } else {
            var collect = Array<NSData>()
            for cert in certs {
                if let d = cert.certData {
                    collect.append(d)
                }
            }
            self.certificates = collect
            self.isReady = true
        }
    }
    
    /**
    Valid the trust and domain name.
    
    - parameter trust: is the serverTrust to validate
    - parameter domain: is the CN domain to validate
    
    - returns: if the key was successfully validated
    */
    func isValid(trust: SecTrustRef, domain: String?) -> Bool {
        
        var tries = 0
        while(!self.isReady) {
            usleep(1000)
            tries += 1
            if tries > 5 {
                return false //doesn't appear it is going to ever be ready...
            }
        }
        var policy: SecPolicyRef
        if self.validatedDN {
            policy = SecPolicyCreateSSL(true, domain)
        } else {
            policy = SecPolicyCreateBasicX509()
        }
        SecTrustSetPolicies(trust,policy)
        if self.usePublicKeys {
            if let keys = self.pubKeys {
                var trustedCount = 0
                let serverPubKeys = publicKeyChainForTrust(trust)
                for serverKey in serverPubKeys as [AnyObject] {
                    for key in keys as [AnyObject] {
                        if serverKey.isEqual(key) {
                            trustedCount += 1
                            break
                        }
                    }
                }
                if trustedCount == serverPubKeys.count {
                    return true
                }
            }
        } else if let certs = self.certificates {
            let serverCerts = certificateChainForTrust(trust)
            var collect = Array<SecCertificate>()
            for cert in certs {
                collect.append(SecCertificateCreateWithData(nil,cert)!)
            }
            SecTrustSetAnchorCertificates(trust,collect)
            var result: SecTrustResultType = SecTrustResultType.Invalid
            SecTrustEvaluate(trust,&result)
            let r = result
            if r == SecTrustResultType.Unspecified || r == SecTrustResultType.Proceed {
                var trustedCount = 0
                for serverCert in serverCerts {
                    for cert in certs {
                        if cert == serverCert {
                            trustedCount += 1
                            break
                        }
                    }
                }
                if trustedCount == serverCerts.count {
                    return true
                }
            }
        }
        return false
    }
    
    /**
    Get the public key from a certificate data
    
    - parameter data: is the certificate to pull the public key from
    
    - returns: a public key
    */
    func extractPublicKey(data: NSData) -> SecKeyRef? {
        let possibleCert = SecCertificateCreateWithData(nil,data)
        if let cert = possibleCert {
            return extractPublicKeyFromCert(cert, policy: SecPolicyCreateBasicX509())
        }
        return nil
    }
    
    /**
    Get the public key from a certificate
    
    - parameter data: is the certificate to pull the public key from
    
    - returns: a public key
    */
    func extractPublicKeyFromCert(cert: SecCertificate, policy: SecPolicy) -> SecKeyRef? {
        var possibleTrust: SecTrust?
        SecTrustCreateWithCertificates(cert, policy, &possibleTrust)
        if let trust = possibleTrust {
            var result: SecTrustResultType = SecTrustResultType.Invalid
            SecTrustEvaluate(trust, &result)
            return SecTrustCopyPublicKey(trust)
        }
        return nil
    }
    
    /**
    Get the certificate chain for the trust
    
    - parameter trust: is the trust to lookup the certificate chain for
    
    - returns: the certificate chain for the trust
    */
    func certificateChainForTrust(trust: SecTrustRef) -> Array<NSData> {
        var collect = Array<NSData>()
        for i in 0 ..< SecTrustGetCertificateCount(trust) {
            let cert = SecTrustGetCertificateAtIndex(trust,i)
            collect.append(SecCertificateCopyData(cert!))
        }
        return collect
    }
    
    /**
    Get the public key chain for the trust
    
    - parameter trust: is the trust to lookup the certificate chain and extract the public keys
    
    - returns: the public keys from the certifcate chain for the trust
    */
    func publicKeyChainForTrust(trust: SecTrustRef) -> Array<SecKeyRef> {
        var collect = Array<SecKeyRef>()
        let policy = SecPolicyCreateBasicX509()
        for i in 0 ..< SecTrustGetCertificateCount(trust) {
            let cert = SecTrustGetCertificateAtIndex(trust,i)
            if let key = extractPublicKeyFromCert(cert!, policy: policy) {
                collect.append(key)
            }
        }
        return collect
    }
    
    
}
