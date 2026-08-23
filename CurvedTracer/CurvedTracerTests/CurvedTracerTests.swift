//
//  CurvedTracerTests.swift
//  CurvedTracerTests
//

import Testing
@testable import CurvedTracer

struct CurvedTracerTests {

    @Test func renderResolutionDefaultsAndValidation() {
        #expect(RenderResolution.hd720.width == 1280)
        #expect(RenderResolution.hd720.height == 720)
        #expect(RenderResolution.hd720.aspectRatio == 16.0 / 9.0)
        #expect(RenderResolution(width: 1024, height: 768).aspectRatio == 4.0 / 3.0)
        #expect(RenderResolution.isValid(width: 1, height: 1))
        #expect(!RenderResolution.isValid(width: 0, height: 720))
        #expect(!RenderResolution.isValid(width: 1280, height: -1))
    }

}
