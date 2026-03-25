//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit

final class SquirrelPanel: NSPanel {
  private let view: SquirrelView
  private let glassView: SquirrelGlassView
  private let back: NSView
  private let panelContent: NSView
  var inputController: SquirrelInputController?

  var position: NSRect
  private var screenRect: NSRect = .zero
  private var maxHeight: CGFloat = 0

  private var statusMessage: String = ""
  private var statusTimer: Timer?

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var candidates: [String] = .init()
  private var comments: [String] = .init()
  private var labels: [String] = .init()
  private var index: Int = 0
  private var cursorIndex: Int = 0
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private var page: Int = 0
  private var lastPage: Bool = true
  private var pagingUp: Bool?

  init(position: NSRect) {
    self.position = position
    self.view = SquirrelView(frame: position)
    self.glassView = SquirrelGlassView(frame: position)
    self.panelContent = NSView(frame: position)
    if #available(macOS 26.0, *) {
      self.back = NSGlassEffectView()
    } else {
      self.back = NSVisualEffectView()
    }
    super.init(contentRect: position, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    self.level = .init(Int(CGShieldingWindowLevel()))
    self.hasShadow = true
    self.isOpaque = false
    self.backgroundColor = .clear

    if let back = back as? NSVisualEffectView {
      back.blendingMode = .behindWindow
      back.material = .hudWindow
      back.state = .active
    } else if #available(macOS 26.0, *), let back = back as? NSGlassEffectView {
      back.style = .regular
      back.tintColor = nil
    }

    back.wantsLayer = true
    panelContent.addSubview(view)
    panelContent.addSubview(view.textView)
    panelContent.addSubview(glassView)
    let contentView = NSView()
    contentView.addSubview(back)
    // Keep the content layers above the glass background. Putting the text
    // stack inside NSGlassEffectView can make the marked text/candidate text
    // disappear on Tahoe in practice.
    contentView.addSubview(panelContent)
    self.contentView = contentView
  }

  var linear: Bool {
    view.currentTheme.linear
  }
  var vertical: Bool {
    view.currentTheme.vertical
  }
  var inlinePreedit: Bool {
    view.currentTheme.inlinePreedit
  }
  var inlineCandidate: Bool {
    view.currentTheme.inlineCandidate
  }

  private var visualBack: NSVisualEffectView? {
    back as? NSVisualEffectView
  }
  private var usesModernGlassLayout: Bool {
    view.currentTheme.usesSystemGlass && !view.currentTheme.vertical
  }

  // swiftlint:disable:next cyclomatic_complexity
  override func sendEvent(_ event: NSEvent) {
    if usesModernGlassLayout {
      switch event.type {
      case .leftMouseDown:
        let point = glassMousePosition()
        pagingUp = glassView.pagingDirection(at: point)
        if pagingUp == nil {
          cursorIndex = glassView.candidateIndex(at: point) ?? index
          glassView.setHoveredCandidate(cursorIndex)
        }
      case .leftMouseUp:
        let point = glassMousePosition()
        if let pagingUp = glassView.pagingDirection(at: point), pagingUp == self.pagingUp {
          _ = inputController?.page(up: pagingUp)
        } else {
          pagingUp = nil
        }
        if let selected = glassView.candidateIndex(at: point), selected == cursorIndex, selected >= 0, selected < candidates.count {
          _ = inputController?.selectCandidate(selected)
        }
      case .mouseEntered:
        acceptsMouseMovedEvents = true
      case .mouseExited:
        acceptsMouseMovedEvents = false
        pagingUp = nil
        cursorIndex = index
        glassView.setHoveredCandidate(nil)
      case .mouseMoved:
        let hoveredIndex = glassView.candidateIndex(at: glassMousePosition())
        if hoveredIndex != glassView.hoveredCandidateIndex {
          cursorIndex = hoveredIndex ?? index
          glassView.setHoveredCandidate(hoveredIndex)
        }
      case .scrollWheel:
        if event.phase == .began {
          scrollDirection = .zero
        } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
          if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
            _ = inputController?.page(up: scrollDirection.dx < 0)
          } else if abs(scrollDirection.dy) > 10 {
            _ = inputController?.page(up: scrollDirection.dy > 0)
          }
          scrollDirection = .zero
        } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
          if scrollTime.timeIntervalSinceNow < -1 {
            scrollDirection = .zero
          }
          scrollTime = .now
          if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
            scrollDirection.dy += event.scrollingDeltaY
          } else {
            scrollDirection = .zero
          }
          if abs(scrollDirection.dy) > 10 {
            _ = inputController?.page(up: scrollDirection.dy > 0)
            scrollDirection = .zero
          }
        } else {
          scrollDirection.dx += event.scrollingDeltaX
          scrollDirection.dy += event.scrollingDeltaY
        }
      default:
        break
      }
      super.sendEvent(event)
      return
    }

    switch event.type {
    case .leftMouseDown:
      let (index, _, pagingUp) =  view.click(at: mousePosition())
      if let pagingUp {
        self.pagingUp = pagingUp
      } else {
        self.pagingUp = nil
      }
      if let index, index >= 0 && index < candidates.count {
        self.index = index
      }
    case .leftMouseUp:
      let (index, preeditIndex, pagingUp) = view.click(at: mousePosition())

      if let pagingUp, pagingUp == self.pagingUp {
        _ = inputController?.page(up: pagingUp)
      } else {
        self.pagingUp = nil
      }
      if let preeditIndex, preeditIndex >= 0 && preeditIndex < preedit.utf16.count {
        if preeditIndex < caretPos {
          _ = inputController?.moveCaret(forward: true)
        } else if preeditIndex > caretPos {
          _ = inputController?.moveCaret(forward: false)
        }
      }
      if let index, index == self.index && index >= 0 && index < candidates.count {
        _ = inputController?.selectCandidate(index)
      }
    case .mouseEntered:
      acceptsMouseMovedEvents = true
    case .mouseExited:
      acceptsMouseMovedEvents = false
      if cursorIndex != index {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
      pagingUp = nil
    case .mouseMoved:
      let (index, _, _) = view.click(at: mousePosition())
      if let index = index, cursorIndex != index && index >= 0 && index < candidates.count {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
    case .scrollWheel:
      if event.phase == .began {
        scrollDirection = .zero
        // Scrollboard span
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
        // Mouse scroll wheel
      } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
        if scrollTime.timeIntervalSinceNow < -1 {
          scrollDirection = .zero
        }
        scrollTime = .now
        if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
          scrollDirection.dy += event.scrollingDeltaY
        } else {
          scrollDirection = .zero
        }
        if abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
          scrollDirection = .zero
        }
      } else {
        scrollDirection.dx += event.scrollingDeltaX
        scrollDirection.dy += event.scrollingDeltaY
      }
    default:
      break
    }
    super.sendEvent(event)
  }

  func hide() {
    statusTimer?.invalidate()
    statusTimer = nil
    orderOut(nil)
    maxHeight = 0
  }

  // Main function to add attributes to text output from librime
  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  func update(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted index: Int, page: Int, lastPage: Bool, update: Bool) {
    if update {
      self.preedit = preedit
      self.selRange = selRange
      self.caretPos = caretPos
      self.candidates = candidates
      self.comments = comments
      self.labels = labels
      self.index = index
      self.page = page
      self.lastPage = lastPage
    }
    cursorIndex = index

    if !candidates.isEmpty || !preedit.isEmpty {
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      if !statusMessage.isEmpty {
        show(status: statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
      return
    }

    let theme = view.currentTheme
    currentScreen()

    if usesModernGlassLayout {
      let glassCandidates = candidates.enumerated().map { offset, candidate in
        SquirrelGlassCandidate(
          index: offset,
          label: candidateLabel(at: offset, labels: labels, theme: theme),
          candidate: candidate.precomposedStringWithCanonicalMapping,
          comment: comments.indices.contains(offset) ? comments[offset].precomposedStringWithCanonicalMapping : ""
        )
      }
      glassView.render(
        theme: theme,
        preedit: preedit,
        selRange: selRange,
        candidates: glassCandidates,
        highlightedIndex: index,
        hoveredIndex: cursorIndex == index ? nil : cursorIndex,
        canPageUp: page > 0,
        canPageDown: !lastPage,
        statusMessage: nil
      )
      show()
      return
    }

    let text = NSMutableAttributedString()
    let preeditRange: NSRange
    let highlightedPreeditRange: NSRange

    // preedit
    if !preedit.isEmpty {
      preeditRange = NSRange(location: 0, length: preedit.utf16.count)
      highlightedPreeditRange = selRange

      let line = NSMutableAttributedString(string: preedit)
      line.addAttributes(theme.preeditAttrs, range: preeditRange)
      line.addAttributes(theme.preeditHighlightedAttrs, range: selRange)
      text.append(line)

      text.addAttribute(.paragraphStyle, value: theme.preeditParagraphStyle, range: NSRange(location: 0, length: text.length))
      if !candidates.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
    } else {
      preeditRange = .empty
      highlightedPreeditRange = .empty
    }

    // candidates
    var candidateRanges = [NSRange]()
    for i in 0..<candidates.count {
      let attrs = i == index ? theme.highlightedAttrs : theme.attrs
      let labelAttrs = i == index ? theme.labelHighlightedAttrs : theme.labelAttrs
      let commentAttrs = i == index ? theme.commentHighlightedAttrs : theme.commentAttrs

      let label = if theme.candidateFormat.contains(/\[label\]/) {
        if labels.count > 1 && i < labels.count {
          labels[i]
        } else if labels.count == 1 && i < labels.first!.count {
          // custom: A. B. C...
          String(labels.first![labels.first!.index(labels.first!.startIndex, offsetBy: i)])
        } else {
          // default: 1. 2. 3...
          "\(i+1)"
        }
      } else {
        ""
      }

      let candidate = candidates[i].precomposedStringWithCanonicalMapping
      let comment = comments[i].precomposedStringWithCanonicalMapping

      let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: labelAttrs)
      for range in line.string.ranges(of: /\[candidate\]/) {
        let convertedRange = convert(range: range, in: line.string)
        line.addAttributes(attrs, range: convertedRange)
        if candidate.count <= 5 {
          line.addAttribute(.noBreak, value: true, range: NSRange(location: convertedRange.location+1, length: convertedRange.length-1))
        }
      }
      for range in line.string.ranges(of: /\[comment\]/) {
        line.addAttributes(commentAttrs, range: convert(range: range, in: line.string))
      }
      line.mutableString.replaceOccurrences(of: "[label]", with: label, range: NSRange(location: 0, length: line.length))
      let labeledLine = line.copy() as! NSAttributedString
      line.mutableString.replaceOccurrences(of: "[candidate]", with: candidate, range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[comment]", with: comment, range: NSRange(location: 0, length: line.length))

      if line.length <= 10 {
        line.addAttribute(.noBreak, value: true, range: NSRange(location: 1, length: line.length-1))
      }

      let lineSeparator = NSAttributedString(string: linear ? "  " : "\n", attributes: attrs)
      if i > 0 {
        text.append(lineSeparator)
      }
      let str = lineSeparator.mutableCopy() as! NSMutableAttributedString
      if vertical {
        str.addAttribute(.verticalGlyphForm, value: 1, range: NSRange(location: 0, length: str.length))
      }
      view.separatorWidth = str.boundingRect(with: .zero).width

      let paragraphStyleCandidate = (i == 0 ? theme.firstParagraphStyle : theme.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
      if linear {
        paragraphStyleCandidate.paragraphSpacingBefore -= theme.linespace
        paragraphStyleCandidate.lineSpacing = theme.linespace
      }
      if !linear, let labelEnd = labeledLine.string.firstMatch(of: /\[(candidate|comment)\]/)?.range.lowerBound {
        let labelString = labeledLine.attributedSubstring(from: NSRange(location: 0, length: labelEnd.utf16Offset(in: labeledLine.string)))
        let labelWidth = labelString.boundingRect(with: .zero, options: [.usesLineFragmentOrigin]).width
        paragraphStyleCandidate.headIndent = labelWidth
      }
      line.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: line.length))

      candidateRanges.append(NSRange(location: text.length, length: line.length))
      text.append(line)
    }

    // text done!
    view.textView.textContentStorage?.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: candidateRanges, hilightedIndex: index, preeditRange: preeditRange, highlightedPreeditRange: highlightedPreeditRange, canPageUp: page > 0, canPageDown: !lastPage)
    show()
  }

  func updateStatus(long longMessage: String, short shortMessage: String) {
    let theme = view.currentTheme
    switch theme.statusMessageType {
    case .mix:
      statusMessage = shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      statusMessage = longMessage
    case .short:
      if !shortMessage.isEmpty {
        statusMessage = shortMessage
      } else if let initial = longMessage.first {
        statusMessage = String(initial)
      } else {
        statusMessage = ""
      }
    }
  }

  func load(config: SquirrelConfig, forDarkMode isDark: Bool) {
    if isDark {
      view.darkTheme = SquirrelTheme()
      view.darkTheme.load(config: config, dark: true)
    } else {
      view.lightTheme = SquirrelTheme()
      view.lightTheme.load(config: config, dark: isDark)
    }
  }
}

private extension SquirrelPanel {
  func mousePosition() -> NSPoint {
    var point = NSEvent.mouseLocation
    point = self.convertPoint(fromScreen: point)
    return view.convert(point, from: nil)
  }

  func glassMousePosition() -> NSPoint {
    var point = NSEvent.mouseLocation
    point = self.convertPoint(fromScreen: point)
    return panelContent.convert(point, from: nil)
  }

  func candidateLabel(at index: Int, labels: [String], theme: SquirrelTheme) -> String {
    guard theme.candidateFormat.contains(/\[label\]/) else { return "" }
    if labels.count > 1 && index < labels.count {
      return labels[index]
    }
    if labels.count == 1, let first = labels.first, index < first.count {
      return String(first[first.index(first.startIndex, offsetBy: index)])
    }
    return "\(index + 1)"
  }

  func currentScreen() {
    if let screen = NSScreen.main {
      screenRect = screen.frame
    }
    for screen in NSScreen.screens where screen.frame.contains(position.origin) {
      screenRect = screen.frame
      break
    }
  }

  func maxTextWidth() -> CGFloat {
    let theme = view.currentTheme
    let font: NSFont = theme.font
    let fontScale = font.pointSize / 12
    let textWidthRatio = min(1, 1 / (vertical ? 4 : 3) + fontScale / 12)
    let maxWidth = if vertical {
      screenRect.height * textWidthRatio - theme.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - theme.edgeInset.width * 2
    }
    return maxWidth
  }

  // Get the window size, the windows will be the dirtyRect in
  // SquirrelView.drawRect
  // swiftlint:disable:next cyclomatic_complexity
  func show() {
    currentScreen()
    let theme = view.currentTheme
    if theme.native || view.darkTheme.available {
      self.appearance = NSApp.effectiveAppearance
    } else {
      // user configured only a light theme, set window appearance to light.
      self.appearance = NSAppearance(named: .aqua)
    }

    if usesModernGlassLayout {
      let maxWidth = min(screenRect.width * 0.72, max(220, maxTextWidth() + 40))
      let contentSize = glassView.preferredSize(maxWidth: maxWidth)
      var panelRect = NSRect(
        x: position.minX,
        y: position.minY - SquirrelTheme.offsetHeight - contentSize.height,
        width: min(screenRect.width * 0.95, contentSize.width),
        height: min(screenRect.height * 0.95, contentSize.height)
      )
      if panelRect.maxX > screenRect.maxX {
        panelRect.origin.x = screenRect.maxX - panelRect.width
      }
      if panelRect.minX < screenRect.minX {
        panelRect.origin.x = screenRect.minX
      }
      if panelRect.minY < screenRect.minY {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
      if panelRect.maxY > screenRect.maxY {
        panelRect.origin.y = screenRect.maxY - panelRect.height
      }
      self.setFrame(panelRect, display: true)

      contentView!.boundsRotation = 0
      contentView!.setBoundsOrigin(.zero)
      panelContent.frame = contentView!.bounds
      glassView.frame = panelContent.bounds
      glassView.isHidden = false
      view.isHidden = true
      view.textView.isHidden = true

      if theme.translucency {
        back.layer?.mask = nil
        back.frame = contentView!.bounds
        visualBack?.appearance = NSApp.effectiveAppearance
        if #available(macOS 26.0, *), let back = back as? NSGlassEffectView {
          back.style = .regular
          back.cornerRadius = max(theme.cornerRadius, theme.hilitedCornerRadius, 18)
          back.tintColor = theme.glassDark
            ? NSColor.black.withAlphaComponent(0.20)
            : NSColor.white.withAlphaComponent(0.16)
        }
        back.layer?.cornerRadius = max(theme.cornerRadius, theme.hilitedCornerRadius, 18)
        back.layer?.cornerCurve = .continuous
        back.layer?.borderWidth = 0.5
        back.layer?.borderColor = (
          theme.glassDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.08)
        ).cgColor
        back.isHidden = false
      } else {
        back.isHidden = true
      }
      alphaValue = theme.alpha
      invalidateShadow()
      orderFront(nil)
      return
    }

    // Break line if the text is too long, based on screen size.
    let textWidth = maxTextWidth()
    let maxTextHeight = vertical ? screenRect.width - theme.edgeInset.width * 2 : screenRect.height - theme.edgeInset.height * 2
    view.textContainer.size = NSSize(width: textWidth, height: maxTextHeight)

    var panelRect = NSRect.zero
    // in vertical mode, the width and height are interchanged
    var contentRect = view.contentRect
    if theme.memorizeSize && (vertical && position.midY / screenRect.height < 0.5) ||
        (vertical && position.minX + max(contentRect.width, maxHeight) + theme.edgeInset.width * 2 > screenRect.maxX) {
      if contentRect.width >= maxHeight {
        maxHeight = contentRect.width
      } else {
        contentRect.size.width = maxHeight
        view.textContainer.size = NSSize(width: maxHeight, height: maxTextHeight)
      }
    }

    if vertical {
      panelRect.size = NSSize(width: min(0.95 * screenRect.width, contentRect.height + theme.edgeInset.height * 2),
                              height: min(0.95 * screenRect.height, contentRect.width + theme.edgeInset.width * 2) + theme.pagingOffset)

      // To avoid jumping up and down while typing, use the lower screen when
      // typing on upper, and vice versa
      if position.midY / screenRect.height >= 0.5 {
        panelRect.origin.y = position.minY - SquirrelTheme.offsetHeight - panelRect.height + theme.pagingOffset
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
      // Make the first candidate fixed at the left of cursor
      panelRect.origin.x = position.minX - panelRect.width - SquirrelTheme.offsetHeight
      if view.preeditRange.length > 0, let preeditTextRange = view.convert(range: view.preeditRange) {
        let preeditRect = view.contentRect(range: preeditTextRange)
        panelRect.origin.x += preeditRect.height + theme.edgeInset.width
      }
    } else {
      panelRect.size = NSSize(width: min(0.95 * screenRect.width, contentRect.width + theme.edgeInset.width * 2),
                              height: min(0.95 * screenRect.height, contentRect.height + theme.edgeInset.height * 2))
      panelRect.size.width += theme.pagingOffset
      panelRect.origin = NSPoint(x: position.minX - theme.pagingOffset, y: position.minY - SquirrelTheme.offsetHeight - panelRect.height)
    }
    if panelRect.maxX > screenRect.maxX {
      panelRect.origin.x = screenRect.maxX - panelRect.width
    }
    if panelRect.minX < screenRect.minX {
      panelRect.origin.x = screenRect.minX
    }
    if panelRect.minY < screenRect.minY {
      if vertical {
        panelRect.origin.y = screenRect.minY
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
    }
    if panelRect.maxY > screenRect.maxY {
      panelRect.origin.y = screenRect.maxY - panelRect.height
    }
    if panelRect.minY < screenRect.minY {
      panelRect.origin.y = screenRect.minY
    }
    self.setFrame(panelRect, display: true)

    // rotate the view, the core in vertical mode!
    if vertical {
      contentView!.boundsRotation = -90
      contentView!.setBoundsOrigin(NSPoint(x: 0, y: panelRect.width))
    } else {
      contentView!.boundsRotation = 0
      contentView!.setBoundsOrigin(.zero)
    }
    view.textView.boundsRotation = 0
    view.textView.setBoundsOrigin(.zero)

    panelContent.frame = contentView!.bounds
    glassView.isHidden = true
    view.isHidden = false
    view.textView.isHidden = false
    view.frame = panelContent.bounds
    view.textView.frame = panelContent.bounds
    view.textView.frame.size.width -= theme.pagingOffset
    view.textView.frame.origin.x += theme.pagingOffset
    view.textView.textContainerInset = theme.edgeInset

    if theme.translucency {
      back.layer?.mask = view.shape
      back.frame = contentView!.bounds
      back.frame.size.width += theme.pagingOffset
      visualBack?.appearance = NSApp.effectiveAppearance
      if #available(macOS 26.0, *), theme.usesSystemGlass, let back = back as? NSGlassEffectView {
        back.style = .regular
        back.cornerRadius = max(theme.cornerRadius, theme.hilitedCornerRadius)
        back.tintColor = nil
      }
      back.isHidden = false
    } else {
      back.isHidden = true
    }
    alphaValue = theme.alpha
    invalidateShadow()
    orderFront(nil)
    // voila!
  }

  func show(status message: String) {
    let theme = view.currentTheme
    if usesModernGlassLayout {
      glassView.render(
        theme: theme,
        preedit: "",
        selRange: .empty,
        candidates: [],
        highlightedIndex: -1,
        hoveredIndex: nil,
        canPageUp: false,
        canPageDown: false,
        statusMessage: message
      )
      show()

      statusTimer?.invalidate()
      statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
        self.hide()
      }
      return
    }

    let text = NSMutableAttributedString(string: message, attributes: theme.attrs)
    text.addAttribute(.paragraphStyle, value: theme.paragraphStyle, range: NSRange(location: 0, length: text.length))
    view.textContentStorage.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: [NSRange(location: 0, length: text.length)], hilightedIndex: -1,
                  preeditRange: .empty, highlightedPreeditRange: .empty, canPageUp: false, canPageDown: false)
    show()

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
      self.hide()
    }
  }

  func convert(range: Range<String.Index>, in string: String) -> NSRange {
    let startPos = range.lowerBound.utf16Offset(in: string)
    let endPos = range.upperBound.utf16Offset(in: string)
    return NSRange(location: startPos, length: endPos - startPos)
  }
}

private struct SquirrelGlassCandidate {
  let index: Int
  let label: String
  let candidate: String
  let comment: String
}

private struct SquirrelGlassLayoutResult {
  let totalSize: NSSize
  let preeditFrame: NSRect?
  let statusFrame: NSRect?
  let candidateFrames: [NSRect]
  let pagingUpFrame: NSRect?
  let pagingDownFrame: NSRect?
}

private final class SquirrelGlassPagingButton: NSView {
  private let symbolField = NSTextField(labelWithString: "")
  private var darkStyle = false

  init(symbol: String) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerCurve = .continuous
    symbolField.stringValue = symbol
    symbolField.isBezeled = false
    symbolField.isBordered = false
    symbolField.drawsBackground = false
    symbolField.backgroundColor = .clear
    symbolField.alignment = .center
    addSubview(symbolField)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool {
    true
  }

  func apply(theme: SquirrelTheme) {
    darkStyle = theme.glassDark
    symbolField.font = theme.labelFont.withSize(max(12, theme.labelFont.pointSize - 1))
    symbolField.textColor = darkStyle
      ? NSColor.white.withAlphaComponent(0.78)
      : NSColor.black.withAlphaComponent(0.60)
    layer?.backgroundColor = (
      darkStyle
        ? NSColor.white.withAlphaComponent(0.10)
        : NSColor.black.withAlphaComponent(0.05)
    ).cgColor
    layer?.borderColor = (
      darkStyle
        ? NSColor.white.withAlphaComponent(0.14)
        : NSColor.black.withAlphaComponent(0.06)
    ).cgColor
    layer?.borderWidth = 0.5
  }

  override func layout() {
    super.layout()
    layer?.cornerRadius = bounds.height / 2
    symbolField.frame = bounds
  }
}

private final class SquirrelGlassCandidateChipView: NSView {
  private let labelField = NSTextField(labelWithString: "")
  private let candidateField = NSTextField(labelWithString: "")
  private let commentField = NSTextField(labelWithString: "")
  private var darkStyle = false
  private var highlighted = false
  private var hovered = false
  private var preferredLabelWidth: CGFloat = 0
  private var preferredCandidateWidth: CGFloat = 0
  private var preferredCommentWidth: CGFloat = 0

  var candidateIndex: Int = -1

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerCurve = .continuous
    for field in [labelField, candidateField, commentField] {
      field.isBezeled = false
      field.isBordered = false
      field.drawsBackground = false
      field.backgroundColor = .clear
      field.lineBreakMode = .byTruncatingTail
      field.maximumNumberOfLines = 1
      addSubview(field)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool {
    true
  }

  func apply(candidate: SquirrelGlassCandidate, theme: SquirrelTheme, highlighted: Bool, hovered: Bool) {
    candidateIndex = candidate.index
    darkStyle = theme.glassDark
    self.highlighted = highlighted
    self.hovered = hovered

    labelField.font = theme.labelFont
    candidateField.font = theme.font
    commentField.font = theme.commentFont
    labelField.stringValue = candidate.label
    candidateField.stringValue = candidate.candidate
    commentField.stringValue = candidate.comment
    preferredLabelWidth = SquirrelGlassMeasure.textWidth(labelField)
    preferredCandidateWidth = SquirrelGlassMeasure.textWidth(candidateField)
    preferredCommentWidth = SquirrelGlassMeasure.textWidth(commentField)
    updateStyle()
    needsLayout = true
  }

  func preferredSize(maxWidth: CGFloat) -> NSSize {
    let contentHeight = max(
      SquirrelGlassMeasure.textHeight(labelField),
      SquirrelGlassMeasure.textHeight(candidateField),
      SquirrelGlassMeasure.textHeight(commentField)
    )
    let totalWidth = 20
      + preferredLabelWidth
      + preferredCandidateWidth
      + preferredCommentWidth
      + (labelField.stringValue.isEmpty ? 0 : 6)
      + (commentField.stringValue.isEmpty ? 0 : 8)
    return NSSize(width: min(maxWidth, max(64, totalWidth)), height: max(32, contentHeight + 14))
  }

  override func layout() {
    super.layout()
    let insetX: CGFloat = 10
    let insetY: CGFloat = 7
    let availableWidth = max(0, bounds.width - insetX * 2)
    let availableHeight = max(0, bounds.height - insetY * 2)
    var x = insetX

    let labelGap: CGFloat = labelField.stringValue.isEmpty ? 0 : 6
    let commentGap: CGFloat = commentField.stringValue.isEmpty ? 0 : 8
    let labelWidth = min(preferredLabelWidth, availableWidth * 0.25)
    let reservedAfterLabel = labelGap + commentGap + min(preferredCommentWidth, availableWidth * 0.34)
    let candidateWidth = max(
      min(preferredCandidateWidth, availableWidth - labelWidth - reservedAfterLabel),
      min(preferredCandidateWidth, availableWidth * 0.35)
    )
    let commentWidth = max(0, availableWidth - labelWidth - labelGap - candidateWidth - commentGap)

    if !labelField.stringValue.isEmpty {
      labelField.frame = NSRect(
        x: x,
        y: insetY + (availableHeight - SquirrelGlassMeasure.textHeight(labelField)) / 2,
        width: labelWidth,
        height: SquirrelGlassMeasure.textHeight(labelField)
      )
      x = labelField.frame.maxX + labelGap
    } else {
      labelField.frame = .zero
    }

    candidateField.frame = NSRect(
      x: x,
      y: insetY + (availableHeight - SquirrelGlassMeasure.textHeight(candidateField)) / 2,
      width: max(0, min(candidateWidth, bounds.maxX - x - insetX)),
      height: SquirrelGlassMeasure.textHeight(candidateField)
    )
    x = candidateField.frame.maxX

    if !commentField.stringValue.isEmpty && commentWidth > 12 {
      x += commentGap
      commentField.frame = NSRect(
        x: x,
        y: insetY + (availableHeight - SquirrelGlassMeasure.textHeight(commentField)) / 2,
        width: max(0, min(commentWidth, bounds.maxX - x - insetX)),
        height: SquirrelGlassMeasure.textHeight(commentField)
      )
    } else {
      commentField.frame = .zero
    }
    layer?.cornerRadius = bounds.height / 2
  }

  private func updateStyle() {
    let primaryColor = darkStyle
      ? NSColor.white.withAlphaComponent(0.96)
      : NSColor.black.withAlphaComponent(0.92)
    let secondaryColor = darkStyle
      ? NSColor.white.withAlphaComponent(highlighted ? 0.82 : 0.70)
      : NSColor.black.withAlphaComponent(highlighted ? 0.74 : 0.58)

    candidateField.textColor = primaryColor
    labelField.textColor = secondaryColor
    commentField.textColor = secondaryColor

    if highlighted {
      layer?.backgroundColor = (
        darkStyle
          ? NSColor.white.withAlphaComponent(0.18)
          : NSColor.black.withAlphaComponent(0.08)
      ).cgColor
      layer?.borderWidth = 0.5
      layer?.borderColor = (
        darkStyle
          ? NSColor.white.withAlphaComponent(0.18)
          : NSColor.black.withAlphaComponent(0.06)
      ).cgColor
      layer?.shadowColor = (
        darkStyle
          ? NSColor.black.withAlphaComponent(0.28)
          : NSColor.black.withAlphaComponent(0.10)
      ).cgColor
      layer?.shadowOpacity = 1
      layer?.shadowRadius = 8
      layer?.shadowOffset = NSSize(width: 0, height: 1)
    } else if hovered {
      layer?.backgroundColor = (
        darkStyle
          ? NSColor.white.withAlphaComponent(0.12)
          : NSColor.black.withAlphaComponent(0.05)
      ).cgColor
      layer?.borderWidth = 0
      layer?.borderColor = nil
      layer?.shadowOpacity = 0
    } else {
      layer?.backgroundColor = NSColor.clear.cgColor
      layer?.borderWidth = 0
      layer?.borderColor = nil
      layer?.shadowOpacity = 0
    }
  }
}

private final class SquirrelGlassView: NSView {
  private let preeditField = NSTextField(labelWithString: "")
  private let statusField = NSTextField(labelWithString: "")
  private let pagingUpView = SquirrelGlassPagingButton(symbol: "⌃")
  private let pagingDownView = SquirrelGlassPagingButton(symbol: "⌄")

  private var currentTheme = SquirrelTheme()
  private var preedit = ""
  private var selRange: NSRange = .empty
  private var candidates: [SquirrelGlassCandidate] = []
  private var highlightedIndex = -1
  private(set) var hoveredCandidateIndex: Int?
  private var canPageUp = false
  private var canPageDown = false
  private var statusMessage: String?
  private var candidateViews: [SquirrelGlassCandidateChipView] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    for field in [preeditField, statusField] {
      field.isBezeled = false
      field.isBordered = false
      field.drawsBackground = false
      field.backgroundColor = .clear
      field.maximumNumberOfLines = 0
      addSubview(field)
    }
    addSubview(pagingUpView)
    addSubview(pagingDownView)
    statusField.alignment = .center
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool {
    true
  }

  func render(theme: SquirrelTheme, preedit: String, selRange: NSRange, candidates: [SquirrelGlassCandidate], highlightedIndex: Int, hoveredIndex: Int?, canPageUp: Bool, canPageDown: Bool, statusMessage: String?) {
    currentTheme = theme
    self.preedit = preedit
    self.selRange = selRange
    self.candidates = candidates
    self.highlightedIndex = highlightedIndex
    hoveredCandidateIndex = hoveredIndex
    self.canPageUp = canPageUp
    self.canPageDown = canPageDown
    self.statusMessage = statusMessage

    while candidateViews.count < candidates.count {
      let chip = SquirrelGlassCandidateChipView(frame: .zero)
      candidateViews.append(chip)
      addSubview(chip)
    }
    while candidateViews.count > candidates.count {
      let chip = candidateViews.removeLast()
      chip.removeFromSuperview()
    }

    updateFields()
    updateCandidateViews()
    needsLayout = true
  }

  func setHoveredCandidate(_ index: Int?) {
    hoveredCandidateIndex = index
    updateCandidateViews()
  }

  func candidateIndex(at point: NSPoint) -> Int? {
    for view in candidateViews where !view.isHidden && view.frame.contains(point) {
      return view.candidateIndex
    }
    return nil
  }

  func pagingDirection(at point: NSPoint) -> Bool? {
    if !pagingUpView.isHidden && pagingUpView.frame.contains(point) {
      return true
    }
    if !pagingDownView.isHidden && pagingDownView.frame.contains(point) {
      return false
    }
    return nil
  }

  func preferredSize(maxWidth: CGFloat) -> NSSize {
    layoutResult(maxWidth: maxWidth).totalSize
  }

  override func layout() {
    super.layout()
    apply(layout: layoutResult(maxWidth: max(bounds.width, 1)))
  }

  private func updateFields() {
    let primaryColor = currentTheme.glassDark
      ? NSColor.white.withAlphaComponent(0.96)
      : NSColor.black.withAlphaComponent(0.92)
    let secondaryColor = currentTheme.glassDark
      ? NSColor.white.withAlphaComponent(0.74)
      : NSColor.black.withAlphaComponent(0.60)

    preeditField.font = currentTheme.font
    statusField.font = currentTheme.font

    if let statusMessage, !statusMessage.isEmpty {
      statusField.isHidden = false
      statusField.attributedStringValue = NSAttributedString(
        string: statusMessage,
        attributes: [
          .font: currentTheme.font,
          .foregroundColor: primaryColor
        ]
      )
    } else {
      statusField.isHidden = true
      statusField.attributedStringValue = NSAttributedString(string: "")
    }

    if !preedit.isEmpty && statusMessage == nil {
      let attr = NSMutableAttributedString(
        string: preedit,
        attributes: [
          .font: currentTheme.font,
          .foregroundColor: secondaryColor
        ]
      )
      let upperBound = min(attr.length, selRange.location + selRange.length)
      if selRange.length > 0, selRange.location < attr.length, upperBound > selRange.location {
        attr.addAttributes([
          .foregroundColor: primaryColor,
          .backgroundColor: (
            currentTheme.glassDark
              ? NSColor.white.withAlphaComponent(0.14)
              : NSColor.black.withAlphaComponent(0.08)
          )
        ], range: NSRange(location: selRange.location, length: upperBound - selRange.location))
      }
      preeditField.isHidden = false
      preeditField.attributedStringValue = attr
    } else {
      preeditField.isHidden = true
      preeditField.attributedStringValue = NSAttributedString(string: "")
    }

    pagingUpView.isHidden = !(currentTheme.showPaging && canPageUp)
    pagingDownView.isHidden = !(currentTheme.showPaging && canPageDown)
    pagingUpView.apply(theme: currentTheme)
    pagingDownView.apply(theme: currentTheme)
  }

  private func updateCandidateViews() {
    let activeHighlightIndex = hoveredCandidateIndex ?? highlightedIndex
    for (offset, candidate) in candidates.enumerated() {
      guard offset < candidateViews.count else { continue }
      let hovered = hoveredCandidateIndex == candidate.index && hoveredCandidateIndex != highlightedIndex
      candidateViews[offset].isHidden = false
      candidateViews[offset].apply(
        candidate: candidate,
        theme: currentTheme,
        highlighted: candidate.index == activeHighlightIndex,
        hovered: hovered
      )
    }
    for offset in candidates.count..<candidateViews.count {
      candidateViews[offset].isHidden = true
    }
  }

  private func layoutResult(maxWidth: CGFloat) -> SquirrelGlassLayoutResult {
    let horizontalInset: CGFloat = 12
    let verticalInset: CGFloat = 10
    let rowSpacing: CGFloat = 8
    let chipSpacing: CGFloat = 8
    let pagingWidth: CGFloat = currentTheme.showPaging ? 24 : 0
    let usableWidth = max(120, maxWidth - horizontalInset * 2 - pagingWidth)

    var currentY = verticalInset
    var maxContentWidth: CGFloat = 0
    var preeditFrame: NSRect?
    var statusFrame: NSRect?

    if !statusField.isHidden {
      let statusSize = SquirrelGlassMeasure.textSize(statusField.attributedStringValue, width: usableWidth)
      statusFrame = NSRect(x: horizontalInset, y: currentY, width: statusSize.width, height: statusSize.height)
      currentY += statusSize.height + verticalInset
      maxContentWidth = max(maxContentWidth, statusSize.width)
    } else if !preeditField.isHidden {
      let preeditSize = SquirrelGlassMeasure.textSize(preeditField.attributedStringValue, width: usableWidth)
      preeditFrame = NSRect(x: horizontalInset, y: currentY, width: preeditSize.width, height: preeditSize.height)
      currentY += preeditSize.height + rowSpacing
      maxContentWidth = max(maxContentWidth, preeditSize.width)
    }

    var candidateFrames = Array(repeating: NSRect.zero, count: candidates.count)
    if currentTheme.linear {
      var currentX = horizontalInset
      var lineHeight: CGFloat = 0
      for (offset, candidateView) in candidateViews.prefix(candidates.count).enumerated() {
        let size = candidateView.preferredSize(maxWidth: usableWidth)
        if currentX > horizontalInset && currentX + size.width > horizontalInset + usableWidth {
          currentX = horizontalInset
          currentY += lineHeight + chipSpacing
          lineHeight = 0
        }
        candidateFrames[offset] = NSRect(x: currentX, y: currentY, width: size.width, height: size.height)
        currentX += size.width + chipSpacing
        lineHeight = max(lineHeight, size.height)
        maxContentWidth = max(maxContentWidth, candidateFrames[offset].maxX - horizontalInset)
      }
      currentY += lineHeight
    } else {
      for (offset, candidateView) in candidateViews.prefix(candidates.count).enumerated() {
        let height = candidateView.preferredSize(maxWidth: usableWidth).height
        candidateFrames[offset] = NSRect(x: horizontalInset, y: currentY, width: usableWidth, height: height)
        currentY += height + chipSpacing
        maxContentWidth = max(maxContentWidth, usableWidth)
      }
      if !candidateFrames.isEmpty {
        currentY -= chipSpacing
      }
    }

    var pagingUpFrame: NSRect?
    var pagingDownFrame: NSRect?
    if currentTheme.showPaging {
      let buttonSize = NSSize(width: 20, height: 20)
      let pagingX = horizontalInset + maxContentWidth + 6
      if canPageUp {
        pagingUpFrame = NSRect(x: pagingX, y: verticalInset, width: buttonSize.width, height: buttonSize.height)
      }
      if canPageDown {
        pagingDownFrame = NSRect(x: pagingX, y: currentY - buttonSize.height, width: buttonSize.width, height: buttonSize.height)
      }
    }

    let totalWidth = horizontalInset * 2 + maxContentWidth + pagingWidth
    let totalHeight = max(currentY + verticalInset, 40)
    return SquirrelGlassLayoutResult(
      totalSize: NSSize(width: totalWidth, height: totalHeight),
      preeditFrame: preeditFrame,
      statusFrame: statusFrame,
      candidateFrames: candidateFrames,
      pagingUpFrame: pagingUpFrame,
      pagingDownFrame: pagingDownFrame
    )
  }

  private func apply(layout: SquirrelGlassLayoutResult) {
    preeditField.frame = layout.preeditFrame ?? .zero
    statusField.frame = layout.statusFrame ?? .zero
    for (offset, frame) in layout.candidateFrames.enumerated() where offset < candidateViews.count {
      candidateViews[offset].frame = frame
    }
    pagingUpView.frame = layout.pagingUpFrame ?? .zero
    pagingDownView.frame = layout.pagingDownFrame ?? .zero
  }
}

private enum SquirrelGlassMeasure {
  static func textWidth(_ field: NSTextField) -> CGFloat {
    textSize(field.attributedStringValue).width
  }

  static func textHeight(_ field: NSTextField) -> CGFloat {
    max(ceil(textSize(field.attributedStringValue).height), 16)
  }

  static func textSize(_ attributedString: NSAttributedString, width: CGFloat = .greatestFiniteMagnitude) -> NSSize {
    guard attributedString.length > 0 else { return .zero }
    let rect = attributedString.boundingRect(
      with: NSSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).integral
    return NSSize(width: ceil(rect.width), height: ceil(rect.height))
  }
}
