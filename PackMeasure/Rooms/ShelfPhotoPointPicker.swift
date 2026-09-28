import SwiftUI

/// A full, uncropped portrait camera image. Pan/zoom only changes its display;
/// selection always maps back to normalized coordinates in the original image.
struct PhotoOutline {
    var points: [CGPoint?]
    var closed: Bool
}

struct ShelfPhotoPointPicker: UIViewRepresentable {
    let image: UIImage
    @Binding var point: CGPoint?
    var outlines: [PhotoOutline] = []
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Canvas {
        let view = Canvas()
        view.backgroundColor = .black
        view.delegate = context.coordinator
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        view.setImage(image)
        return view
    }
    func updateUIView(_ view: Canvas, context: Context) {
        context.coordinator.parent = self
        view.setOutlines(outlines)
        view.setPoint(point)
    }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ShelfPhotoPointPicker
        init(_ parent: ShelfPhotoPointPicker) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? Canvas)?.photoView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? Canvas)?.centerImage() }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? Canvas else { return }
            let p = gesture.location(in: view.photoView), size = view.photoView.bounds.size
            guard size.width > 0, size.height > 0, view.photoView.bounds.contains(p) else { return }
            parent.point = CGPoint(x: p.x / size.width, y: p.y / size.height)
        }
    }
    @MainActor final class Canvas: UIScrollView {
        let photoView = UIImageView()
        private let cross = CAShapeLayer()
        private let outlineLayer = CAShapeLayer()
        private var outlines: [PhotoOutline] = []
        private var fittedSize: CGSize = .zero
        private var selected: CGPoint?
        override init(frame: CGRect) {
            super.init(frame: frame)
            photoView.clipsToBounds = true
            addSubview(photoView); photoView.layer.addSublayer(outlineLayer); photoView.layer.addSublayer(cross)
            outlineLayer.strokeColor = UIColor.systemTeal.cgColor; outlineLayer.fillColor = nil
            cross.strokeColor = UIColor.systemYellow.cgColor; cross.fillColor = nil
            showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
            bouncesZoom = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func setImage(_ image: UIImage) {
            photoView.image = image
            photoView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let image = photoView.image, bounds.width > 0, bounds.height > 0 else { return }
            if fittedSize != bounds.size {
                fittedSize = bounds.size
                let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
                minimumZoomScale = fit; maximumZoomScale = fit * 8; zoomScale = fit
            }
            centerImage()
        }
        func setOutlines(_ outlines: [PhotoOutline]) { self.outlines = outlines; drawOutlines() }
        private func drawOutlines() {
            let path = UIBezierPath()
            func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * photoView.bounds.width, y: p.y * photoView.bounds.height) }
            let radius = 4 / max(zoomScale, 0.001)
            outlineLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            for (loopIndex, outline) in outlines.enumerated() {
                var previous: CGPoint?
                for (pointIndex, value) in outline.points.enumerated() {
                    guard let value else { previous = nil; continue }
                    let p = pixel(value)
                    if let previous { path.move(to: previous); path.addLine(to: p) }
                    previous = p
                    let label = CATextLayer()
                    label.string = loopIndex == 0 ? "\(pointIndex + 1)" : "O\(loopIndex)·\(pointIndex + 1)"
                    label.fontSize = 12 / max(zoomScale, 0.001)
                    label.foregroundColor = UIColor.white.cgColor
                    label.backgroundColor = UIColor.black.withAlphaComponent(0.65).cgColor
                    label.alignmentMode = .center; label.contentsScale = 3
                    let width: CGFloat = loopIndex == 0 ? 22 : 42
                    label.frame = CGRect(x: p.x + radius, y: p.y + radius, width: width / max(zoomScale, 0.001), height: 17 / max(zoomScale, 0.001))
                    outlineLayer.addSublayer(label)
                    path.append(UIBezierPath(ovalIn: CGRect(x: p.x-radius, y: p.y-radius, width: radius*2, height: radius*2)))
                }
                if outline.closed, outline.points.allSatisfy({ $0 != nil }), let first = outline.points.first ?? nil, let previous {
                    path.move(to: previous); path.addLine(to: pixel(first))
                }
            }
            outlineLayer.path = path.cgPath; outlineLayer.lineWidth = 2 / max(zoomScale, 0.001)
        }
        func setPoint(_ point: CGPoint?) { selected = point; drawCross() }
        func centerImage() {
            let x = max(0, (bounds.width - photoView.frame.width) / 2)
            let y = max(0, (bounds.height - photoView.frame.height) / 2)
            let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
            if contentInset != inset { contentInset = inset }
            drawCross(); drawOutlines()
        }
        private func drawCross() {
            guard let selected else { cross.path = nil; return }
            let p = CGPoint(x: selected.x * photoView.bounds.width, y: selected.y * photoView.bounds.height)
            let radius = 12 / max(zoomScale, 0.001)
            let gap = 3 / max(zoomScale, 0.001)
            let path = UIBezierPath()
            path.move(to: CGPoint(x:p.x-radius,y:p.y)); path.addLine(to:CGPoint(x:p.x-gap,y:p.y))
            path.move(to: CGPoint(x:p.x+gap,y:p.y)); path.addLine(to:CGPoint(x:p.x+radius,y:p.y))
            path.move(to: CGPoint(x:p.x,y:p.y-radius)); path.addLine(to:CGPoint(x:p.x,y:p.y-gap))
            path.move(to: CGPoint(x:p.x,y:p.y+gap)); path.addLine(to:CGPoint(x:p.x,y:p.y+radius))
            cross.path = path.cgPath; cross.lineWidth = 2 / max(zoomScale, 0.001)
        }
    }
}

struct ShelfReferencePhoto: View {
    let image: UIImage
    let point: CGPoint
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / image.size.width, proxy.size.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            ZStack {
                Image(uiImage: image).resizable().scaledToFit()
                Image(systemName: "plus").foregroundStyle(.yellow).font(.system(size: 14, weight: .bold))
                    .position(x: (proxy.size.width - size.width) / 2 + point.x * size.width,
                              y: (proxy.size.height - size.height) / 2 + point.y * size.height)
            }
        }.background(.black).clipShape(RoundedRectangle(cornerRadius: 6)).allowsHitTesting(false)
    }
}
