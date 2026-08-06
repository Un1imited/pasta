import Foundation
import Vision
import ImageIO

/// 图片文字识别（Vision，本地推理零网络）：识别结果进搜索索引，让截图可以按内容搜到。
/// 全部在自有串行低优先级队列上跑，一次一张，不与 UI/剪贴板监听抢资源。
enum OCRService {
    private static let queue = DispatchQueue(label: "com.local.pasta.ocr", qos: .utility)

    /// 识别图片里的文字，完成后在本队列回调（调用方自行切主线程）。
    /// data 由 provider 惰性提供并在本队列执行——回填历史图片时的文件读取不占主线程。
    /// 识别不到文字或数据无效时回调 nil。
    static func recognize(provider: @escaping () -> Data?, completion: @escaping (String?) -> Void) {
        queue.async {
            guard let data = provider(),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                completion(nil)
                return
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                completion(nil)
                return
            }
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            completion(text.isEmpty ? nil : text)
        }
    }
}
