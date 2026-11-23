import Foundation
import Testing
@testable import VoiceLoop

/// Standard IPA, as a language model writes it, in Kokoro's notation: what the on-device
/// suggester does with each pronunciation the model gives it.
@Suite struct IPAToMisakiTests {
    private func misaki(_ ipa: String, asOneWord: Bool = false) -> String {
        MisakiPhonemes.fromIPA(ipa, asOneWord: asOneWord)
    }

    @Test func eachDiphthongIsItsCapital() {
        #expect(misaki("ˈseɪ") == "sˈA")
        #expect(misaki("ˈaɪ") == "ˈI")
        #expect(misaki("ˈɡoʊ") == "ɡˈO")
        #expect(misaki("ˈnaʊ") == "nˈW")
        #expect(misaki("ˈbɔɪ") == "bˈY")
    }

    @Test func aStressMarkMovesFromTheSyllablesStartToRightBeforeItsVowel() {
        #expect(misaki("həˈloʊ") == "həlˈO")
        #expect(misaki("ˈwɪnstən") == "wˈɪnstən")
        #expect(misaki("ˈstraɪk") == "stɹˈIk")
        #expect(misaki("ˌkæləˈfɔrnjə") == "kˌæləfˈɔɹnjə")
        #expect(misaki("ˌɪtsiˈbɪtsi") == "ˌɪtsibˈɪtsi")
    }

    @Test func aStressMarkWithNoVowelAfterItIsDroppedAndPrimaryStressWins() {
        #expect(misaki("ˈpst") == "pst")
        #expect(misaki("ˌˈæp") == "ˈæp")
    }

    @Test func aStressMarkGoesBeforeAnIPAVowelMisakiDoesntUseToo() {
        // Lübeck: Kokoro's vocabulary has y.
        #expect(misaki("ˈlyːbɛk") == "lˈybɛk")
        // Müller: the stress goes before ʏ too, though Kokoro's vocabulary lacks it.
        #expect(misaki("ˈmʏlɐ") == "mˈʏlə")
    }

    @Test func rAndGAreMisakis() {
        #expect(misaki("ˈɡrin") == "ɡɹˈin")
        #expect(misaki("ˈgrin") == "ɡɹˈin")
        #expect(misaki("əˈraɪvd") == "əɹˈIvd")
    }

    @Test func affricatesAreOneSymbolWithOrWithoutATieBar() {
        #expect(misaki("ˈtʃɝtʃ") == "ʧˈɜɹʧ")
        #expect(misaki("ˈdʒʌdʒ") == "ʤˈʌʤ")
        #expect(misaki("ˈt͡ʃɪp") == "ʧˈɪp")
        #expect(misaki("ˈd͡ʒɪm") == "ʤˈɪm")
    }

    @Test func syllableDotsAndLengthMarksAreRemoved() {
        #expect(misaki("ˈwɪn.stən") == "wˈɪnstən")
        #expect(misaki("ˈkɑː.fiː") == "kˈɑfi")
        #expect(misaki("ˈseɪ.ɪŋ") == "sˈAɪŋ")
        #expect(misaki("ˈpʰɪn") == "pˈɪn")
    }

    @Test func aSyllableDotKeepsTheVowelsOnEitherSideApart() {
        // Joined, o and ɪ would be the diphthong of "boy".
        #expect(misaki("ˈɡo.ɪŋ") == "ɡˈOɪŋ")
        #expect(misaki("ˈɡoɪŋ") == "ɡˈYŋ")
    }

    @Test func aHyphenBetweenSyllablesIsASyllableBreak() {
        #expect(misaki("kɪn-ˈwɑː") == "kɪnwˈɑ")
        #expect(misaki("ˈɡo-ɪŋ") == "ɡˈOɪŋ")
    }

    @Test func inOneWordASpaceIsASyllableBreak() {
        #expect(misaki("ˈɡo ɪŋ", asOneWord: true) == "ɡˈOɪŋ")
        #expect(misaki(" ˈwɪn  stən ", asOneWord: true) == "wˈɪnstən")
        // Otherwise it parts words.
        #expect(misaki("ˈɡo ɪŋ") == "ɡˈO ɪŋ")
    }

    @Test func theSlashesOrBracketsAroundATranscriptionAreDropped() {
        #expect(misaki("/ˈwɪn.stən/") == "wˈɪnstən")
        #expect(misaki("[ˈwɪn.stən]") == "wˈɪnstən")
    }

    @Test func rColoredVowelsAreAVowelAndɹ() {
        #expect(misaki("ˈbʌtɚ") == "bˈʌtəɹ")
        #expect(misaki("ˈbʌɾɚ") == "bˈʌɾəɹ")
        #expect(misaki("ˈbɝd") == "bˈɜɹd")
        #expect(misaki("ˈbɜrd") == "bˈɜɹd")
        // American English says ɜ only before an r.
        #expect(misaki("ˈbɜːd") == "bˈɜɹd")
    }

    @Test func aBareEIsTheVowelOfBedAndTheVowelOfSayIsEɪOrEː() {
        #expect(misaki("ˈbed") == "bˈɛd")
        #expect(misaki("ˈbɛd") == "bˈɛd")
        #expect(misaki("ˈbeɪk") == "bˈAk")
        #expect(misaki("ˈbeːk") == "bˈAk")
        #expect(misaki("ˈber") == "bˈɛɹ")
        #expect(misaki("ˈbɛr") == "bˈɛɹ")
    }

    @Test func eiInOneSyllableIsTheVowelOfSayAndAcrossASyllableBreakTwoVowels() {
        #expect(misaki("ˈbeik") == "bˈAk")
        // ei̯, with its non-syllabic mark.
        #expect(misaki("ˈbei\u{032F}k") == "bˈAk")
        // Deity.
        #expect(misaki("ˈde.ɪ.ti") == "dˈɛɪti")
        #expect(misaki("ˈde.i.ti") == "dˈɛiti")
    }

    @Test func anOptionalSoundIsReadWithoutItThenWithIt() {
        #expect(MisakiPhonemes.readings(ofIPA: "ˈsɪbə(h)n") == ["ˈsɪbən", "ˈsɪbəhn"])
        #expect(MisakiPhonemes.readings(ofIPA: "ˈwɪnstən") == ["ˈwɪnstən"])
    }

    @Test func aParenthesisWithoutItsPairOrInsideAnotherIsLeftAsItIs() {
        #expect(MisakiPhonemes.readings(ofIPA: "ˈsɪbə(hn") == ["ˈsɪbə(hn"])
        #expect(MisakiPhonemes.readings(ofIPA: "ˈsɪbəh)n") == ["ˈsɪbəh)n"])
        #expect(MisakiPhonemes.readings(ofIPA: "ˈsɪ((b))ən") == ["ˈsɪ((b))ən"])
    }

    @Test func onlyTheFirstThreeOptionalSoundsAreReadBothWays() {
        let readings = MisakiPhonemes.readings(ofIPA: "(a)(b)(c)(d)")
        #expect(readings == ["d", "cd", "bd", "bcd", "ad", "acd", "abd", "abcd"])
    }

    @Test func aRhoticHookIsAnR() {
        #expect(misaki("ˈbʌtə˞") == "bˈʌtəɹ")
        #expect(misaki("ˈbɜ˞d") == "bˈɜɹd")
    }

    @Test func oIsTheVowelOfOrBeforeAnRAndOfGoElsewhere() {
        #expect(misaki("ˈfor") == "fˈɔɹ")
        #expect(misaki("ˈɡo") == "ɡˈO")
    }

    @Test func aLongEOrOIsADiphthongEvenBeforeAnR() {
        // As the model wrote Kokoro.
        #expect(misaki("kɔˈroːro") == "kɔɹˈOɹO")
        #expect(misaki("ˈseːra") == "sˈAɹɑ")
        #expect(misaki("ˈɡnoːki") == "ɡnˈOki")
    }

    @Test func otherVowelsMisakiWritesOtherwise() {
        #expect(misaki("ˈfaðɚ") == "fˈɑðəɹ")
        #expect(misaki("ˈlɒt") == "lˈɑt")
        #expect(misaki("ˈrʉd") == "ɹˈud")
        #expect(misaki("ˈroʊzɨz") == "ɹˈOzᵻz")
        #expect(misaki("ˈfiɫ") == "fˈil")
    }

    @Test func aSyllabicConsonantGetsTheFaintVowelBeforeIt() {
        #expect(misaki("ˈbʌtn̩") == "bˈʌtᵊn")
        #expect(misaki("ˈlɪtl̩") == "lˈɪtᵊl")
        #expect(misaki("ˈbʌtɹ̩") == "bˈʌtəɹ")
    }

    @Test func wordsAreConvertedEachOnItsOwnAndKeptApartByOneSpace() {
        #expect(misaki("  ˈnu   ˈjɔrk ") == "nˈu jˈɔɹk")
        #expect(misaki(" . ") == "")
    }

    @Test func symbolsItDoesntConvertAreKept() {
        #expect(misaki("ˈlɑx") == "lˈɑx")
        #expect(misaki("ˈbʌʔn") == "bˈʌʔn")
    }

    @Test func diacriticsAreDroppedWhetherTheLetterComesWithItsOwnOrNot() {
        // ĩ as one character (U+0129), and as i and a combining tilde.
        #expect(misaki("[b\u{0129}n]") == "bin")
        #expect(misaki("[bi\u{0303}n]") == "bin")
        #expect(misaki("ˈk\u{00E9}fe") == "kˈɛfɛ")
    }

    @Test func aLetterOfItsOwnInIPAWithADiacriticInItIsKept() {
        // ç, as one character and as c with a combining cedilla: one character either way.
        let precomposed = misaki("ˈ\u{00E7}iː")
        let decomposed = misaki("ˈc\u{0327}iː")
        #expect(precomposed == "\u{00E7}ˈi")
        #expect(decomposed == "\u{00E7}ˈi")
        #expect(precomposed.unicodeScalars.first == "\u{00E7}")
        #expect(MisakiPhonemes.unknownSymbols(in: precomposed, symbols: MisakiPhonemes.usSymbols) == ["\u{00E7}"])
    }
}

/// What settings lists for the suggestions a `PronunciationSuggester` gives.
@Suite struct PronunciationCandidateTests {
    private func suggestion(_ phonemes: String, _ respelling: String = "", _ note: String = "") -> PronunciationSuggestion {
        PronunciationSuggestion(phonemes: phonemes, respelling: respelling, note: note)
    }

    @Test func eachSymbolIsCheckedAgainstTheOnesKokoroHas() {
        let candidates = PronunciationCandidate.candidates(
            from: [suggestion("wˈɪnstən"), suggestion("lˈɑx"), suggestion("ʔy ʔ")],
            symbols: MisakiPhonemes.usSymbols
        )

        #expect(candidates.map(\.unknownSymbols) == [[], ["x"], ["ʔ", "y"]])
        #expect(candidates.map(\.isUsable) == [true, false, false])
        // With a vocabulary that has it, x is fine.
        let withX = PronunciationCandidate.candidates(from: [suggestion("lˈɑx")], symbols: MisakiPhonemes.usSymbols.union(["x"]))
        #expect(withX.map(\.isUsable) == [true])
    }

    @Test func aRepeatOrOneWithNoPhonemesIsDroppedAndTheRestAreTrimmed() {
        let candidates = PronunciationCandidate.candidates(
            from: [
                suggestion(" wˈɪnstən ", " WIN-stun ", " the usual "),
                suggestion("wˈɪnstən", "WIN-ston", "a repeat"),
                suggestion("  ", "nothing", ""),
                suggestion("wɪnstˈɑn", "win-STON", ""),
            ],
            symbols: MisakiPhonemes.usSymbols
        )

        #expect(candidates.map(\.suggestion) == [
            suggestion("wˈɪnstən", "WIN-stun", "the usual"),
            suggestion("wɪnstˈɑn", "win-STON", ""),
        ])
        #expect(candidates.map(\.id) == ["wˈɪnstən", "wɪnstˈɑn"])
    }

    @Test func misakisUSSymbolsAreTheOnesItsDictionariesUse() {
        // Kokoro's own: "Kokoro", and "isn't" with its faint vowel.
        #expect(MisakiPhonemes.unknownSymbols(in: "kˈOkəɹO ˈɪzᵊnt", symbols: MisakiPhonemes.usSymbols).isEmpty)
        // Standard IPA misaki writes otherwise.
        #expect(MisakiPhonemes.unknownSymbols(in: "rgeoaː", symbols: MisakiPhonemes.usSymbols) == ["r", "g", "e", "o", "a", "ː"])
    }
}
