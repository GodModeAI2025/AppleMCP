import AVFAudio
import Speech
import XCTest
@testable import M3MCPApp

final class AnalyzerInputFormatTests: XCTestCase {
    func testProductionPCMFormatCanCreateNativeAnalyzerInput() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer requires macOS 26") }
        let format = try XCTUnwrap(AVAudioFormat(settings: SpeechTranscription.analyzerPCMOutputSettings))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
        buffer.frameLength = 8192
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for entry in buffers {
            if let bytes = entry.mData { memset(bytes, 0, Int(entry.mDataByteSize)) }
        }
        // Previously the production Float32 format trapped inside this initializer.
        let input = AnalyzerInput(buffer: buffer, bufferStartTime: .zero)
        XCTAssertEqual(input.bufferStartTime, .zero)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
    }
}
