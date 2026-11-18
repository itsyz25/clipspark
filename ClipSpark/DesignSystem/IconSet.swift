import SwiftUI

/// Central icon registry. Original clean-room icons drawn with SF Symbols,
/// styled uniformly: rounded, medium weight.
public enum CSIcon: String, CaseIterable {
    case newProject     = "plus"
    case importMedia    = "photo.on.rectangle.angled"
    case editClip       = "slider.horizontal.3"
    case split          = "arrowtriangle.left.and.right"
    case trim           = "scissors"
    case speed          = "speedometer"
    case audio          = "music.note"
    case text           = "textformat"
    case sticker        = "face.smiling"
    case filter         = "camera.filters"
    case adjust         = "wand.and.stars"
    case overlay        = "square.on.square"
    case effects        = "sparkles"
    case transition     = "arrow.left.arrow.right"
    case undo           = "arrow.uturn.left"
    case redo           = "arrow.uturn.right"
    case play           = "play.fill"
    case pause          = "pause.fill"
    case export         = "square.and.arrow.up"
    case delete         = "trash"
    case duplicate      = "plus.square.on.square"
    case volume         = "speaker.wave.2.fill"
    case settings       = "gearshape"
case keyframe       = "diamond"
    case templates      = "rectangle.stack"
    case drafts         = "tray.full"
    case inbox          = "tray"
    case home           = "house"

    public var symbol: Image {
        Image(systemName: rawValue)
    }
}
