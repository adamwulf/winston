import Foundation
import Testing
@testable import VoiceLoop

/// Standard IPA, as a language model writes it, in Kokoro's notation: what the on-device
/// suggester does with each pronunciation the model gives it.
@Suite struct IPAToMisakiTests {
    private func misaki(_ ipa: String) -> String {
        MisakiPhonemes.fromIPA(ipa)
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

    @Test func rColoredVowelsAreAVowelAndɹ() {
        #expect(misaki("ˈbʌtɚ") == "bˈʌtəɹ")
        #expect(misaki("ˈbʌɾɚ") == "bˈʌɾəɹ")
        #expect(misaki("ˈbɝd") == "bˈɜɹd")
        #expect(misaki("ˈbɜrd") == "bˈɜɹd")
        // American English says ɜ only before an r.
        #expect(misaki("ˈbɜːd") == "bˈɜɹd")
    }

    @Test func eAndOAreTheVowelsOfAirAndOrBeforeAnRAndDiphthongsElsewhere() {
        #expect(misaki("ˈker") == "kˈɛɹ")
        #expect(misaki("ˈfor") == "fˈɔɹ")
        #expect(misaki("ˈmek") == "mˈAk")
        #expect(misaki("ˈɡo") == "ɡˈO")
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
