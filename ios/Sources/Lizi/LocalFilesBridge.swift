import Foundation
import UIKit
import WebKit
import UniformTypeIdentifiers

/// 本地音乐导入桥：前端 window.webkit.messageHandlers.liziNative.postMessage({type:'importLocal'})。
///
/// 只在用户点「导入本地音乐」时弹系统文件选择器（UIDocumentPickerViewController，
/// UTType.audio，允许多选），不申请任何隐私权限——选择器本身就是用户手势授权。
/// 选完在后台线程拷进沙盒（LocalMusic.importFiles），完成后再回主线程发
/// lizi:local-imported 事件，前端收到后刷新本地列表。
/// 和 LyricsBridge 同款写法：WKScriptMessageHandler 回调在主线程。
final class LocalFilesBridge: NSObject, WKScriptMessageHandler, UIDocumentPickerDelegate {
    weak var webView: WKWebView?
    private var pickerPresented = false

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "liziNative",
              let body = message.body as? [String: Any],
              body["type"] as? String == "importLocal" else { return }
        presentPicker()
    }

    private func presentPicker() {
        // WKScriptMessageHandler 回调本来就在主线程；不是主线程时切过去再弹。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.presentPicker() }
            return
        }
        guard !pickerPresented else { return }
        guard let presenter = topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        pickerPresented = true
        presenter.present(picker, animated: true)
    }

    /// 沿着 presentedViewController 链找到最顶上的，避免根 VC 已有弹窗时 present 失败。
    private func topViewController() -> UIViewController? {
        var top = webView?.window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        pickerPresented = false
        guard !urls.isEmpty else { return }
        // 拷文件 + 读元数据放后台线程，别卡主线程；完成后再回主线程通知前端。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = LocalMusic.importFiles(urls: urls)
            DispatchQueue.main.async {
                self?.notifyImported(count: result.imported.count, failed: result.failed)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerPresented = false
    }

    private func notifyImported(count: Int, failed: Int) {
        let js = "window.dispatchEvent(new CustomEvent('lizi:local-imported', { detail: { count: \(count), failed: \(failed) } }))"
        webView?.evaluateJavaScript(js)
    }
}
