import SwiftUI
import VoiceLoop
import WinstonCore

/// An IPA pronunciation's Suggest button: it opens a list of suggested phonemes for the word, from
/// Apple Intelligence on this device. Disabled while the word is blank. Shown even when Apple
/// Intelligence can't run: the list then says why, and what would let it.
struct PronunciationSuggestButton: View {
    @Environment(AppModel.self) private var model
    let word: String
    let pronunciationID: Pronunciation.ID
    /// The open list's suggestions; nil while it is closed.
    @State private var suggestions: PronunciationSuggestions?

    var body: some View {
        Button {
            // The list asks as it shows.
            openSuggestions.wrappedValue = model.pronunciationSuggestions(for: word)
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
        .popover(item: openSuggestions) { suggestions in
            PronunciationSuggestionsView(suggestions: suggestions, pronunciationID: pronunciationID)
        }
    }

    /// `suggestions`, stopping the open list's request as the list closes. Not as its content
    /// disappears: on the iPhone, where the popover becomes a sheet, the first content shown
    /// disappears right after it shows, while the sheet stays, and that stopped every request and
    /// left the list loading for good.
    private var openSuggestions: Binding<PronunciationSuggestions?> {
        Binding {
            suggestions
        } set: { newValue in
            if let open = suggestions, newValue?.id != open.id {
                open.cancel()
            }
            suggestions = newValue
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
            // Asks once, though the content may show twice (see `PronunciationSuggestButton`).
            // Closing the list stops the request; this content disappearing doesn't.
            .onAppear {
                suggestions.start()
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
                case .loaded(let suggestions) where suggestions.isEmpty:
                    Text("No suggestions. Try Regenerate.")
                        .foregroundStyle(.secondary)
                case .loaded:
                    // Checked against the symbols Kokoro has now: the rows change as its model
                    // loads or is freed.
                    ForEach(suggestions.candidates) { candidate in
                        row(for: candidate)
                    }
                    if let playNote {
                        Text(playNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Suggestions for \(suggestions.word)")
            } footer: {
                // Where they come from, in the suggester's own words. Not beside a failure, such
                // as a device without Apple Intelligence, where there are none.
                if !isFailed {
                    Text(suggestions.attribution + " " + String(localized: "Suggestions are often wrong: play each before you use it."))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isFailed: Bool {
        if case .failed = suggestions.phase { true } else { false }
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

    /// Why the play buttons are off, and what would turn them on; nil while they play.
    private var playNote: LocalizedStringKey? {
        switch model.suggestionPlayback {
        case .plays: nil
        case .needsKokoroVoice: "Choose a Kokoro voice to hear the suggestions."
        case .needsVoiceModel: "Choose a voice model under Kokoro Voices in Settings to hear the suggestions."
        case .waitsForVoiceModel: "The suggestions play once the Kokoro voice model is ready."
        case .voiceModelFailed: "The Kokoro voice model couldn't load. Retry it under Kokoro Voices in Settings to hear the suggestions."
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
