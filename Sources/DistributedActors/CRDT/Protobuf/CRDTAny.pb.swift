// DO NOT EDIT.
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: CRDT/CRDTAny.proto
//
// For information on using the generated types, please see the documenation:
//   https://github.com/apple/swift-protobuf/

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import SwiftProtobuf

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of SwiftProtobuf to which you are linking.
// Please ensure that your are building against the same version of the API
// that was used to generate this file.
private struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
    struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
    typealias Version = _2
}

struct ProtoAnyCvRDT {
    // SwiftProtobuf.Message conformance is added in an extension below. See the
    // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
    // methods supported on all messages.

    var underlyingSerializerID: UInt32 = 0

    var underlyingBytes: Data = SwiftProtobuf.Internal.emptyData

    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}
}

struct ProtoAnyDeltaCRDT {
    // SwiftProtobuf.Message conformance is added in an extension below. See the
    // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
    // methods supported on all messages.

    var underlyingSerializerID: UInt32 = 0

    var underlyingBytes: Data = SwiftProtobuf.Internal.emptyData

    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}
}

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension ProtoAnyCvRDT: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName: String = "AnyCvRDT"
    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "underlyingSerializerId"),
        2: .same(proto: "underlyingBytes"),
    ]

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularUInt32Field(value: &self.underlyingSerializerID)
            case 2: try decoder.decodeSingularBytesField(value: &self.underlyingBytes)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if self.underlyingSerializerID != 0 {
            try visitor.visitSingularUInt32Field(value: self.underlyingSerializerID, fieldNumber: 1)
        }
        if !self.underlyingBytes.isEmpty {
            try visitor.visitSingularBytesField(value: self.underlyingBytes, fieldNumber: 2)
        }
        try self.unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ProtoAnyCvRDT, rhs: ProtoAnyCvRDT) -> Bool {
        if lhs.underlyingSerializerID != rhs.underlyingSerializerID { return false }
        if lhs.underlyingBytes != rhs.underlyingBytes { return false }
        if lhs.unknownFields != rhs.unknownFields { return false }
        return true
    }
}

extension ProtoAnyDeltaCRDT: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName: String = "AnyDeltaCRDT"
    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "underlyingSerializerId"),
        2: .same(proto: "underlyingBytes"),
    ]

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularUInt32Field(value: &self.underlyingSerializerID)
            case 2: try decoder.decodeSingularBytesField(value: &self.underlyingBytes)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if self.underlyingSerializerID != 0 {
            try visitor.visitSingularUInt32Field(value: self.underlyingSerializerID, fieldNumber: 1)
        }
        if !self.underlyingBytes.isEmpty {
            try visitor.visitSingularBytesField(value: self.underlyingBytes, fieldNumber: 2)
        }
        try self.unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ProtoAnyDeltaCRDT, rhs: ProtoAnyDeltaCRDT) -> Bool {
        if lhs.underlyingSerializerID != rhs.underlyingSerializerID { return false }
        if lhs.underlyingBytes != rhs.underlyingBytes { return false }
        if lhs.unknownFields != rhs.unknownFields { return false }
        return true
    }
}