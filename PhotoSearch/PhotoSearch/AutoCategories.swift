import Foundation

/// Zero-shot photo categories via CLIP: each category is a handful of text
/// prompts encoded once with the on-device text encoder; a photo joins a
/// category when its stored image embedding clears the prompt-similarity
/// threshold. No extra models, no re-index — it's the caption-search math
/// pointed at fixed queries.
///
/// Thresholds follow the ViT-B/32 text↔image calibration used for caption
/// search (>0.30 strongly related, <0.22 unrelated), tuned slightly per
/// category: visually distinctive categories (screenshots) can afford a
/// higher bar than diffuse ones (nature).
struct AutoCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let prompts: [String]
    let threshold: Float
}

enum AutoCategorizer {
    static let categories: [AutoCategory] = [
        AutoCategory(id: "screenshots", title: "Screenshots", icon: "iphone",
                     prompts: ["a screenshot of a phone screen",
                               "a screenshot of an app user interface"],
                     threshold: 0.27),
        AutoCategory(id: "documents", title: "Documents", icon: "doc.text",
                     prompts: ["a photo of a paper document",
                               "a photo of a receipt",
                               "a photo of a whiteboard with writing"],
                     threshold: 0.27),
        AutoCategory(id: "memes", title: "Memes", icon: "face.smiling",
                     prompts: ["a funny internet meme with caption text"],
                     threshold: 0.27),
        AutoCategory(id: "food", title: "Food", icon: "fork.knife",
                     prompts: ["a photo of a plate of food",
                               "a photo of a meal at a restaurant"],
                     threshold: 0.25),
        AutoCategory(id: "pets", title: "Pets", icon: "pawprint",
                     prompts: ["a photo of a pet dog",
                               "a photo of a pet cat"],
                     threshold: 0.25),
        AutoCategory(id: "nature", title: "Nature", icon: "leaf",
                     prompts: ["a scenic landscape photo of nature",
                               "a photo of mountains, a beach, or a forest"],
                     threshold: 0.25),
    ]
}
