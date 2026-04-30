import CodexMobileKit
import Foundation
import SwiftUI
import UIKit

@MainActor
protocol WorkspaceFileDataSource {
    func listDirectory(pairing: PairingPayload, relativePath: String) async throws -> WorkspaceDirectoryListing
    func loadFileData(pairing: PairingPayload, relativePath: String, byteLimit: Int) async throws -> Data
}

struct WorkspaceDirectoryListing: Equatable, Sendable {
    var relativePath: String
    var entries: [WorkspaceFileEntry]

    init(relativePath: String, entries: [WorkspaceFileEntry]) {
        self.relativePath = WorkspaceRelativePath.sanitized(relativePath)
        self.entries = entries
    }
}

struct WorkspaceFileEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case directory
        case file
        case symlink
        case unsupported
    }

    var name: String
    var relativePath: String
    var kind: Kind
    var byteCount: Int64?
    var modifiedAt: Date?

    var id: String {
        relativePath.isEmpty ? name : relativePath
    }

    var isImageFile: Bool {
        kind == .file && WorkspaceImageFileSupport.isSupportedImagePath(name)
    }

    init(
        name: String,
        relativePath: String,
        kind: Kind,
        byteCount: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.name = name.isEmpty ? "Untitled" : name
        self.relativePath = WorkspaceRelativePath.sanitized(relativePath)
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

enum WorkspaceImageFileSupport {
    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]

    static func isSupportedImagePath(_ path: String) -> Bool {
        guard let fileExtension = path.split(separator: ".").last else { return false }
        return supportedExtensions.contains(fileExtension.lowercased())
    }
}

struct FilesFeatureView: View {
    @EnvironmentObject private var store: CodexMobileStore

    private let explicitPairing: PairingPayload?
    private let dataSource: (any WorkspaceFileDataSource)?
    private let imagePreviewByteLimit: Int

    @State private var currentRelativePath = ""
    @State private var listing: WorkspaceDirectoryListing?
    @State private var loadState: WorkspaceFilesLoadState = .idle
    @State private var refreshToken = 0
    @State private var previewFile: WorkspaceFileEntry?
    @State private var notice: WorkspaceFilesNotice?

    init(
        pairing: PairingPayload? = nil,
        dataSource: (any WorkspaceFileDataSource)? = nil,
        imagePreviewByteLimit: Int = WorkspaceFileLimits.defaultImagePreviewBytes
    ) {
        self.explicitPairing = pairing
        self.dataSource = dataSource
        self.imagePreviewByteLimit = imagePreviewByteLimit
    }

    var body: some View {
        let pairing = activePairing

        VStack(spacing: 0) {
            header(pairing: pairing)
            Divider().overlay(FilesPanelTheme.separator)
            breadcrumbBar
            Divider().overlay(FilesPanelTheme.separator)
            content(pairing: pairing)
        }
        .background(FilesPanelTheme.appBackground.ignoresSafeArea())
        .foregroundStyle(FilesPanelTheme.text)
        .task(id: taskKey(pairing: pairing)) {
            await loadDirectory(pairing: pairing)
        }
        .onChange(of: pairing?.cwd) { _, _ in
            currentRelativePath = ""
            listing = nil
            notice = nil
            refreshToken += 1
        }
        .sheet(item: $previewFile) { file in
            ImagePreviewView(
                pairing: pairing,
                file: file,
                dataSource: dataSource,
                byteLimit: imagePreviewByteLimit
            )
            .presentationDetents([.large])
            .preferredColorScheme(.dark)
        }
    }

    private var activePairing: PairingPayload? {
        explicitPairing ?? store.pairing
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    navigate(to: "")
                } label: {
                    Label("工作区", systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(FilesBreadcrumbButtonStyle(isSelected: currentRelativePath.isEmpty))

                let components = WorkspaceRelativePath.components(currentRelativePath)
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FilesPanelTheme.tertiaryText)
                    Button {
                        navigate(to: WorkspaceRelativePath.path(for: components, through: index))
                    } label: {
                        Text(component)
                            .lineLimit(1)
                    }
                    .buttonStyle(FilesBreadcrumbButtonStyle(isSelected: index == components.count - 1))
                }
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(FilesPanelTheme.panel)
    }

    private func header(pairing: PairingPayload?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.title3.weight(.semibold))
                .foregroundStyle(FilesPanelTheme.blue)
                .frame(width: 34, height: 34)
                .background(FilesPanelTheme.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("文件")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(FilesPanelTheme.text)
                Text(pairing?.name ?? "未配对")
                    .font(.caption)
                    .foregroundStyle(FilesPanelTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                navigateUp()
            } label: {
                Image(systemName: "arrow.up")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(currentRelativePath.isEmpty ? FilesPanelTheme.tertiaryText : FilesPanelTheme.text)
            .disabled(currentRelativePath.isEmpty)
            .accessibilityLabel("返回上级目录")

            Button {
                refreshToken += 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(FilesPanelTheme.text)
            .disabled(loadState == .loading)
            .accessibilityLabel("刷新目录")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(FilesPanelTheme.appBackground)
    }

    @ViewBuilder
    private func content(pairing: PairingPayload?) -> some View {
        switch loadState {
        case .idle, .loading:
            FilesStatusView(
                icon: "folder.badge.questionmark",
                title: "正在加载目录",
                detail: "正在读取工作区内的相对路径。",
                isLoading: true
            )
        case let .failed(message):
            FilesStatusView(
                icon: "exclamationmark.triangle",
                title: "无法加载文件",
                detail: message,
                isLoading: false
            )
        case let .unsupported(message):
            FilesStatusView(
                icon: "wrench.and.screwdriver",
                title: "文件协议未接线",
                detail: message,
                isLoading: false
            )
        case .loaded:
            if let listing {
                directoryList(listing: listing, pairing: pairing)
            } else {
                FilesStatusView(
                    icon: "folder",
                    title: "目录为空",
                    detail: "当前路径没有可显示的条目。",
                    isLoading: false
                )
            }
        }
    }

    private func directoryList(listing: WorkspaceDirectoryListing, pairing: PairingPayload?) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let notice {
                    FilesInlineNoticeView(notice: notice)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }

                let entries = sortedEntries(listing.entries)
                if entries.isEmpty {
                    FilesStatusView(
                        icon: "folder",
                        title: "目录为空",
                        detail: "当前路径没有可显示的条目。",
                        isLoading: false
                    )
                    .frame(minHeight: 360)
                } else {
                    ForEach(entries) { entry in
                        Button {
                            open(entry, pairing: pairing)
                        } label: {
                            WorkspaceFileRow(
                                entry: entry,
                                imagePreviewByteLimit: imagePreviewByteLimit
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isActionable(entry))

                        if entry.id != entries.last?.id {
                            Divider()
                                .overlay(FilesPanelTheme.separator)
                                .padding(.leading, 60)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .background(FilesPanelTheme.appBackground)
    }

    private func taskKey(pairing: PairingPayload?) -> String {
        [
            pairing?.name ?? "no-pairing",
            pairing?.cwd ?? "no-cwd",
            currentRelativePath,
            String(refreshToken),
        ].joined(separator: "|")
    }

    private func loadDirectory(pairing: PairingPayload?) async {
        guard let pairing else {
            listing = nil
            loadState = .unsupported("请先完成配对；文件面板只会从配对工作区根目录开始浏览。")
            return
        }

        guard let dataSource else {
            listing = nil
            loadState = .unsupported("主界面还没有传入 WorkspaceFileDataSource。接线后需要实现目录列表和文件数据读取。")
            return
        }

        loadState = .loading
        notice = nil
        do {
            let loadedListing = try await dataSource.listDirectory(
                pairing: pairing,
                relativePath: currentRelativePath
            )
            let resolvedPath = WorkspaceRelativePath.relativePath(
                from: loadedListing.relativePath,
                cwd: pairing.cwd,
                fallback: currentRelativePath
            )
            if resolvedPath != currentRelativePath {
                currentRelativePath = resolvedPath
            }
            listing = WorkspaceDirectoryListing(
                relativePath: currentRelativePath,
                entries: loadedListing.entries.map { normalizedEntry($0, pairing: pairing) }
            )
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            listing = nil
            loadState = .failed(error.localizedDescription)
        }
    }

    private func normalizedEntry(_ entry: WorkspaceFileEntry, pairing: PairingPayload) -> WorkspaceFileEntry {
        let fallbackPath = WorkspaceRelativePath.appending(entry.name, to: currentRelativePath)
        let relativePath = WorkspaceRelativePath.relativePath(
            from: entry.relativePath,
            cwd: pairing.cwd,
            fallback: fallbackPath
        )
        return WorkspaceFileEntry(
            name: entry.name,
            relativePath: relativePath,
            kind: entry.kind,
            byteCount: entry.byteCount,
            modifiedAt: entry.modifiedAt
        )
    }

    private func open(_ entry: WorkspaceFileEntry, pairing: PairingPayload?) {
        notice = nil
        switch entry.kind {
        case .directory:
            navigate(to: entry.relativePath)
        case .file:
            guard entry.isImageFile else {
                notice = WorkspaceFilesNotice(
                    icon: "doc",
                    title: "暂不支持预览此文件",
                    detail: "文件面板当前只预览 png, jpg, jpeg, gif, webp, heic, tiff 图片。"
                )
                return
            }
            if let byteCount = entry.byteCount, byteCount > Int64(imagePreviewByteLimit) {
                previewFile = entry
            } else if pairing == nil || dataSource == nil {
                notice = WorkspaceFilesNotice(
                    icon: "wrench.and.screwdriver",
                    title: "图片预览不可用",
                    detail: "配对或文件数据源未接线，无法读取图片数据。"
                )
            } else {
                previewFile = entry
            }
        case .symlink, .unsupported:
            notice = WorkspaceFilesNotice(
                icon: "questionmark.folder",
                title: "暂不支持打开此条目",
                detail: "为了避免跳出配对工作区，文件面板不会跟随符号链接或未知文件类型。"
            )
        }
    }

    private func isActionable(_ entry: WorkspaceFileEntry) -> Bool {
        switch entry.kind {
        case .directory, .file, .symlink, .unsupported:
            true
        }
    }

    private func navigate(to relativePath: String) {
        let sanitizedPath = WorkspaceRelativePath.sanitized(relativePath)
        guard sanitizedPath != currentRelativePath else { return }
        currentRelativePath = sanitizedPath
        listing = nil
        notice = nil
    }

    private func navigateUp() {
        let components = WorkspaceRelativePath.components(currentRelativePath)
        guard !components.isEmpty else { return }
        currentRelativePath = components.dropLast().joined(separator: "/")
        listing = nil
        notice = nil
    }

    private func sortedEntries(_ entries: [WorkspaceFileEntry]) -> [WorkspaceFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.kind == .directory, rhs.kind != .directory { return true }
            if lhs.kind != .directory, rhs.kind == .directory { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

struct ImagePreviewView: View {
    @Environment(\.dismiss) private var dismiss

    var pairing: PairingPayload?
    var file: WorkspaceFileEntry
    var dataSource: (any WorkspaceFileDataSource)?
    var byteLimit: Int = WorkspaceFileLimits.defaultImagePreviewBytes

    @State private var state: WorkspaceImagePreviewState = .idle

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
            Divider().overlay(FilesPanelTheme.separator)
            previewContent
        }
        .background(FilesPanelTheme.appBackground.ignoresSafeArea())
        .task(id: file.id) {
            await loadPreview()
        }
    }

    private var previewHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.title3.weight(.semibold))
                .foregroundStyle(FilesPanelTheme.blue)
                .frame(width: 34, height: 34)
                .background(FilesPanelTheme.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(FilesPanelTheme.text)
                    .lineLimit(1)
                Text(previewSubtitle)
                    .font(.caption)
                    .foregroundStyle(FilesPanelTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(FilesPanelTheme.text)
            .accessibilityLabel("关闭图片预览")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch state {
        case .idle, .loading:
            FilesStatusView(
                icon: "photo",
                title: "正在加载图片",
                detail: "预览只会读取大小限制内的图片数据。",
                isLoading: true
            )
        case let .tooLarge(actualBytes, limitBytes):
            FilesStatusView(
                icon: "externaldrive.badge.exclamationmark",
                title: "图片过大",
                detail: "此图片大小为 \(ByteCountFormatter.workspaceFileString(from: actualBytes))，超过 \(ByteCountFormatter.workspaceFileString(from: Int64(limitBytes))) 预览限制。请在电脑端打开。",
                isLoading: false
            )
        case let .failed(message):
            FilesStatusView(
                icon: "xmark.octagon",
                title: "无法预览图片",
                detail: message,
                isLoading: false
            )
        case let .loaded(image, byteCount):
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(18)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(ByteCountFormatter.workspaceFileString(from: byteCount))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FilesPanelTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(FilesPanelTheme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
            }
        }
    }

    private var previewSubtitle: String {
        if let byteCount = file.byteCount {
            return ByteCountFormatter.workspaceFileString(from: byteCount)
        }
        return file.relativePath.isEmpty ? "工作区图片" : file.relativePath
    }

    private func loadPreview() async {
        guard WorkspaceImageFileSupport.isSupportedImagePath(file.name) else {
            state = .failed("文件扩展名不在图片预览白名单内。")
            return
        }
        guard let pairing else {
            state = .failed("请先完成配对后再预览工作区图片。")
            return
        }
        guard let dataSource else {
            state = .failed("主界面还没有传入 WorkspaceFileDataSource，无法读取图片数据。")
            return
        }
        if let byteCount = file.byteCount, byteCount > Int64(byteLimit) {
            state = .tooLarge(actualBytes: byteCount, limitBytes: byteLimit)
            return
        }

        state = .loading
        do {
            let data = try await dataSource.loadFileData(
                pairing: pairing,
                relativePath: file.relativePath,
                byteLimit: byteLimit
            )
            guard data.count <= byteLimit else {
                state = .tooLarge(actualBytes: Int64(data.count), limitBytes: byteLimit)
                return
            }
            guard let image = UIImage(data: data) else {
                state = .failed("图片数据已读取，但 UIImage 无法解码。")
                return
            }
            state = .loaded(image: image, byteCount: Int64(data.count))
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private enum WorkspaceFilesLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
    case unsupported(String)
}

private enum WorkspaceImagePreviewState {
    case idle
    case loading
    case loaded(image: UIImage, byteCount: Int64)
    case tooLarge(actualBytes: Int64, limitBytes: Int)
    case failed(String)
}

private struct WorkspaceFilesNotice: Equatable {
    var icon: String
    var title: String
    var detail: String
}

private enum WorkspaceFileLimits {
    static let defaultImagePreviewBytes = 12 * 1024 * 1024
}

private enum WorkspaceRelativePath {
    static func sanitized(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        var components: [String] = []
        for rawComponent in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(rawComponent)
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
                continue
            }
            components.append(component)
        }
        return components.joined(separator: "/")
    }

    static func components(_ path: String) -> [String] {
        sanitized(path)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    static func path(for components: [String], through index: Int) -> String {
        guard index >= 0, index < components.count else { return "" }
        return components.prefix(index + 1).joined(separator: "/")
    }

    static func appending(_ component: String, to path: String) -> String {
        sanitized((path.isEmpty ? "" : "\(path)/") + component)
    }

    static func relativePath(from path: String, cwd: String, fallback: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return sanitized(fallback) }
        guard trimmedPath.hasPrefix("/") else { return sanitized(trimmedPath) }

        let absolutePath = normalizedAbsolutePath(trimmedPath)
        let workspaceRoot = normalizedAbsolutePath(cwd)
        if workspaceRoot == "/" {
            return sanitized(absolutePath)
        }
        if absolutePath == workspaceRoot {
            return ""
        }
        if absolutePath.hasPrefix(workspaceRoot + "/") {
            return sanitized(String(absolutePath.dropFirst(workspaceRoot.count + 1)))
        }
        return sanitized(fallback)
    }

    private static func normalizedAbsolutePath(_ path: String) -> String {
        let relative = sanitized(path)
        if relative.isEmpty {
            return "/"
        }
        return "/" + relative
    }
}

private struct WorkspaceFileRow: View {
    var entry: WorkspaceFileEntry
    var imagePreviewByteLimit: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconTint)
                .frame(width: 34, height: 34)
                .background(iconTint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(FilesPanelTheme.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(detailText)
                    if isTooLargeImage {
                        Text("超过预览限制")
                            .foregroundStyle(FilesPanelTheme.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(FilesPanelTheme.secondaryText)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if entry.kind == .directory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FilesPanelTheme.tertiaryText)
            } else if entry.isImageFile {
                Image(systemName: "eye")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FilesPanelTheme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch entry.kind {
        case .directory:
            "folder"
        case .file:
            entry.isImageFile ? "photo" : "doc"
        case .symlink:
            "link"
        case .unsupported:
            "questionmark.folder"
        }
    }

    private var iconTint: Color {
        switch entry.kind {
        case .directory:
            FilesPanelTheme.blue
        case .file:
            entry.isImageFile ? FilesPanelTheme.green : FilesPanelTheme.secondaryText
        case .symlink, .unsupported:
            FilesPanelTheme.orange
        }
    }

    private var detailText: String {
        switch entry.kind {
        case .directory:
            return "目录"
        case .file:
            if let byteCount = entry.byteCount {
                return ByteCountFormatter.workspaceFileString(from: byteCount)
            }
            return entry.isImageFile ? "图片" : "文件"
        case .symlink:
            return "符号链接"
        case .unsupported:
            return "未知类型"
        }
    }

    private var isTooLargeImage: Bool {
        guard entry.isImageFile, let byteCount = entry.byteCount else { return false }
        return byteCount > Int64(imagePreviewByteLimit)
    }
}

private struct FilesStatusView: View {
    var icon: String
    var title: String
    var detail: String
    var isLoading: Bool

    var body: some View {
        VStack(spacing: 14) {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(FilesPanelTheme.secondaryText)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(FilesPanelTheme.secondaryText)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(FilesPanelTheme.text)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(FilesPanelTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FilesInlineNoticeView: View {
    var notice: WorkspaceFilesNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.icon)
                .foregroundStyle(FilesPanelTheme.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(FilesPanelTheme.text)
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(FilesPanelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(FilesPanelTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(FilesPanelTheme.orange.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct FilesBreadcrumbButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? FilesPanelTheme.text : FilesPanelTheme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                isSelected ? FilesPanelTheme.selected.opacity(configuration.isPressed ? 0.7 : 1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}

private enum FilesPanelTheme {
    static let appBackground = Color(red: 0.055, green: 0.055, blue: 0.055)
    static let panel = Color(red: 0.105, green: 0.105, blue: 0.105)
    static let panelRaised = Color(red: 0.135, green: 0.135, blue: 0.135)
    static let selected = Color.white.opacity(0.12)
    static let separator = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.34)
    static let green = Color(red: 0.18, green: 0.76, blue: 0.42)
    static let orange = Color(red: 1.0, green: 0.45, blue: 0.18)
    static let blue = Color(red: 0.36, green: 0.63, blue: 1.0)
}

private extension ByteCountFormatter {
    static func workspaceFileString(from byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }
}

@MainActor
private final class FilesFeaturePreviewDataSource: WorkspaceFileDataSource {
    func listDirectory(pairing: PairingPayload, relativePath: String) async throws -> WorkspaceDirectoryListing {
        if relativePath == "Assets" {
            return WorkspaceDirectoryListing(
                relativePath: relativePath,
                entries: [
                    WorkspaceFileEntry(name: "Screenshot.png", relativePath: "Assets/Screenshot.png", kind: .file, byteCount: 58_000),
                    WorkspaceFileEntry(name: "Large.heic", relativePath: "Assets/Large.heic", kind: .file, byteCount: 22_000_000),
                ]
            )
        }
        return WorkspaceDirectoryListing(
            relativePath: "",
            entries: [
                WorkspaceFileEntry(name: "Apps", relativePath: "Apps", kind: .directory),
                WorkspaceFileEntry(name: "Assets", relativePath: "Assets", kind: .directory),
                WorkspaceFileEntry(name: "README.md", relativePath: "README.md", kind: .file, byteCount: 2_400),
                WorkspaceFileEntry(name: "Cover.webp", relativePath: "Cover.webp", kind: .file, byteCount: 124_000),
            ]
        )
    }

    func loadFileData(pairing: PairingPayload, relativePath: String, byteLimit: Int) async throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 560, height: 360))
        return renderer.pngData { context in
            UIColor(red: 0.08, green: 0.10, blue: 0.12, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 560, height: 360))
            UIColor(red: 0.36, green: 0.63, blue: 1.0, alpha: 1).setFill()
            context.fill(CGRect(x: 48, y: 48, width: 464, height: 264))
        }
    }
}

#Preview("Files") {
    let store = CodexMobileStore.preview()
    FilesFeatureView(dataSource: FilesFeaturePreviewDataSource())
        .environmentObject(store)
}
