import SwiftUI
import VoiceLoop
import WinstonCore

/// An IPA pronunciation's Suggest button: it opens a list of suggested phonemes for the word, from
/// Apple Intelligence on this device. Shown only while suggestions can be made, and disabled
/// while the word is blank.
struct PronunciationSuggestButton: View {
    @Environment(AppModel.self) private var model
    let word: String
    let pronunciationID: Pronunciation.ID
    /// The open list's suggestions; nil while it is closed.
    @State private var suggestions: PronunciationSuggestions?

    var body: some View {
        if model.canSuggestPronunciations {
            Button {
                let suggestions = model.pronunciationSuggestions(for: word)
                suggestions.generate()
                self.suggestions = suggestions
            } label: {
                Image(systemName: "sparkles")
                    #if os(iOS)
                    // Borderless, only the symbol itself would take a tap: too small a target.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    #endif
            }
            // Borderless, so on iOS only the button opens the list, not a tap anywhere in the row.
            .buttonStyle(.borderless)
            .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Suggest IPA")
            .accessibilityLabel("Suggest phonemes")
            .popover(item: $suggestions) { suggestions in
                PronunciationSuggestionsView(suggestions: suggestions, pronunciationID: pronunciationID)
            }
        }
    }
}

/// The suggested phonemes for a pronunciation's word: a spinner while they load, then each with
/// its respelling and note, a play button, and Use, which fills the pronunciation's IPA and
/// closes the list. One with a symbol Kokoro doesn't have says so, and can't be played or used.
/// The play buttons work only with a ready Kokoro voice, and a note says so otherwise. Regenerate
/// asks again. A popover on the Mac and the iPad, a sheet on the iPhone.
private struct PronunciationSuggestionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let suggestions: PronunciationSuggestions
    let pronunciationID: Pronunciation.ID

    var body: some View {
        content
            .onDisappear {
                suggestions.cancel()
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        NavigationStack {
            list
                .navigationTitle("Suggestions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        regenerateButton
                    }
                }
        }
        .presentationDetents([.medium, .large])
        #else
        VStack(spacing: 0) {
            list
                // As tall as its rows up to a limit, as the Pronunciations tab is.
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                regenerateButton
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 420)
        #endif
    }

    private var list: some View {
        Form {
            Section {
                switch suggestions.phase {
                case .loading:
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Suggesting…")
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.secondary)
                case .loaded(let candidates) where candidates.isEmpty:
                    Text("No suggestions. Try Regenerate.")
                        .foregroundStyle(.secondary)
                case .loaded(let candidates):
                    ForEach(candidates) { candidate in
                        row(for: candidate)
                    }
                    if !model.canPlaySuggestions {
                        Text(playNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Suggestions for \(suggestions.word)")
            } footer: {
                // Where they come from, in the suggester's own words.
                Text(suggestions.attribution + " " + String(localized: "Suggestions are often wrong: play each before you use it."))
            }
        }
        .formStyle(.grouped)
    }

    private func row(for candidate: PronunciationCandidate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.suggestion.phonemes)
                    .textSelection(.enabled)
                if !candidate.suggestion.respelling.isEmpty {
                    Text(candidate.suggestion.respelling)
                        .foregroundStyle(.secondary)
                }
                if !candidate.suggestion.note.isEmpty {
                    Text(candidate.suggestion.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !candidate.isUsable {
                    Text("Kokoro can't say \(candidate.unknownSymbols.map(String.init).joined(separator: " "))")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            // Only a ready Kokoro voice says the phonemes: any other would say the same written
            // word for every suggestion.
            PlayButton(
                help: "Play Suggestion",
                accessibilityLabel: "Play suggestion",
                isEnabled: candidate.isUsable && model.canPlaySuggestions
            ) {
                model.previewPronunciation(word: suggestions.word, phonemes: candidate.suggestion.phonemes)
            }
            Button("Use") {
                if model.use(candidate, forPronunciation: pronunciationID) {
                    dismiss()
                }
            }
            // Bordered, so on iOS only the button uses it, not a tap anywhere in the row.
            .buttonStyle(.bordered)
            .disabled(!candidate.isUsable)
            .help("Use these phonemes")
        }
    }

    /// Why the play buttons are off, while `AppModel.canPlaySuggestions` is false.
    private var playNote: LocalizedStringKey {
        if model.voiceLoop.chosenVoice?.engine == .kokoro {
            "The suggestions play once the Kokoro voice model is ready."
        } else {
            "Choose a Kokoro voice to hear the suggestions."
        }
    }

    /// On while a request is under way too: `generate()` replaces it, such as one slow to answer.
    private var regenerateButton: some View {
        Button {
            suggestions.generate()
        } label: {
            Label("Regenerate", systemImage: "arrow.clockwise")
        }
        .help("Ask for other suggestions")
    }
}
