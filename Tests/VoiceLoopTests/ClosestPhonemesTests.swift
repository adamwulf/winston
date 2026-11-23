import Testing
@testable import VoiceLoop

/// Speak IPA's closest Kokoro symbol for each one Kokoro lacks.
@Suite struct ClosestPhonemesTests {
    private let symbols = MisakiPhonemes.usSymbols

    @Test func everySoundInTheTableHasAClosestMisakiSymbol() {
        for (symbol, candidates) in ClosestPhonemes.table where !symbols.contains(symbol) && !candidates.isEmpty {
            let closest = ClosestPhonemes.closest(to: symbol, symbols: symbols)
            #expect(!closest.isEmpty, "\(symbol) has nothing close")
            #expect(closest.allSatisfy(symbols.contains), "\(symbol) is put as \(closest), which Kokoro lacks")
        }
    }

    @Test func soundsEnglishDoesntHaveArePutAsTheNearestItDoes() {
        let expected: [Character: String] = [
            // Fricatives: the stop or fricative made nearest.
            "x": "k", "χ": "k", "ɣ": "ɡ", "ç": "ʃ", "ɕ": "ʃ", "ʂ": "ʃ", "β": "v", "ɸ": "f", "ħ": "h", "ɬ": "l",
            // Rhotics, laterals and nasals.
            "r": "ɹ", "ʁ": "ɹ", "ʀ": "ɹ", "ʎ": "j", "ɲ": "nj", "ɴ": "ŋ", "ɱ": "m",
            // Stops, implosives and clicks.
            "c": "k", "ɟ": "ɡ", "q": "k", "ʈ": "t", "ɖ": "d", "g": "ɡ", "ɓ": "b", "ǃ": "k",
            // Affricates as their two sounds, when Kokoro has no single symbol.
            "ʦ": "ts", "ʣ": "dz", "ʨ": "ʧ", "ʥ": "ʤ",
            // Vowels: the nearest English one.
            "y": "u", "ʏ": "ʊ", "ø": "ɜ", "œ": "ɜ", "ɯ": "u", "ɤ": "ʌ", "ɘ": "ə", "ɨ": "ᵻ", "ɐ": "ə", "ɒ": "ɑ",
            "a": "ɑ", "e": "ɛ", "o": "O",
        ]
        for (symbol, closest) in expected {
            #expect(ClosestPhonemes.closest(to: symbol, symbols: symbols) == closest, "\(symbol)")
        }
    }

    @Test func marksWithNoSoundOfTheirOwnAreLeftOut() {
        for symbol: Character in ["ʔ", "ʰ", "ʲ", "ʷ", "ː", "˥", "˩", "|", "‖", "↗"] {
            #expect(ClosestPhonemes.closest(to: symbol, symbols: symbols) == "", "\(symbol)")
        }
    }

    @Test func theNextChoiceIsTakenWhenKokoroLacksTheFirst() {
        #expect(ClosestPhonemes.closest(to: "x", symbols: symbols.subtracting(["k"])) == "h")
        #expect(ClosestPhonemes.closest(to: "ɲ", symbols: symbols.subtracting(["j"])) == "n")
        // misaki's own diphthong, should a Kokoro lack it: its two vowels.
        #expect(ClosestPhonemes.closest(to: "O", symbols: symbols.subtracting(["O"])) == "ɔʊ")
        #expect(ClosestPhonemes.closest(to: "ɾ", symbols: symbols.subtracting(["ɾ"])) == "d")
    }

    @Test func aSymbolNotInTheTableIsPutAsItsLetterWithoutDiacriticsOrInLowercase() {
        // A nasal vowel, precomposed: a, and so ɑ; e, and so ɛ.
        #expect(ClosestPhonemes.closest(to: "\u{00E3}", symbols: symbols) == "ɑ")
        #expect(ClosestPhonemes.closest(to: "\u{1EBD}", symbols: symbols) == "ɛ")
        // A letter Kokoro has, with a diacritic: the letter.
        #expect(ClosestPhonemes.closest(to: "\u{00ED}", symbols: symbols) == "i")
        #expect(ClosestPhonemes.closest(to: "R", symbols: symbols) == "ɹ")
        // A bilabial percussive: nothing close.
        #expect(ClosestPhonemes.closest(to: "ʬ", symbols: symbols) == "")
    }

    @Test func punctuationIsLeftOutThoughKokoroHasIt() {
        #expect(ClosestPhonemes.closest(to: "!", symbols: symbols.union(["!"])) == "")
        let result = ClosestPhonemes.closest("həlˈO!", symbols: symbols.union(["!"]))
        #expect(result.phonemes == "həlˈO")
        #expect(result.changes == [.init(from: "!", to: "")])
    }

    @Test func aWordsPhonemesKeepWhatKokoroHasAndRecordEachChange() {
        let result = ClosestPhonemes.closest("bɑxʔx", symbols: symbols)
        #expect(result.phonemes == "bɑkk")
        #expect(result.changes == [.init(from: "x", to: "k"), .init(from: "ʔ", to: ""), .init(from: "x", to: "k")])
        // A loaded Kokoro with x keeps it.
        let loaded = ClosestPhonemes.closest("bɑx", symbols: symbols.union(["x"]))
        #expect(loaded.phonemes == "bɑx")
        #expect(loaded.changes.isEmpty)
    }
}
