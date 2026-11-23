import Testing
@testable import VoiceLoop

/// What Speak IPA gives the on-device model: a message as plain words, in chunks, each cut into
/// words and what lies between them.
@Suite struct SpeakIPATextTests {
    // MARK: - Normalizing

    @Test func markdownCodeAndLinksAreDroppedAsWhenSpoken() {
        let text = """
            ## Done

            I fixed **two** bugs in `VoiceLoop`, see [the PR](https://example.com/pr/1).
            ```swift
            let x = 1
            ```
            Details at https://example.com/details.
            """
        #expect(SpeakIPAText.normalized(text) == """
            Done.
            I fixed two bugs in VoiceLoop, see the PR.
            Details at a link.
            """)
    }

    @Test func emojiAreLeftOutButDigitsAndSymbolsAreNot() {
        #expect(SpeakIPAText.normalized("Shipped 🚀 and tested ✅👍🏽!") == "Shipped and tested !")
        #expect(SpeakIPAText.normalized("1️⃣ First") == "First.")
        #expect(SpeakIPAText.normalized("Copyright © Adam") == "Copyright © Adam.")
    }

    @Test func numbersAreWordsWithTheirHyphensSaidAsSpaces() {
        #expect(SpeakIPAText.normalized("All 214 passed in 3.5 s.") == "All two hundred fourteen passed in three point five s.")
        #expect(SpeakIPAText.normalized("It costs $25.") == "It costs twenty five dollars.")
    }

    @Test func aHyphenSlashOrUnderscoreBetweenLettersIsASpace() {
        #expect(SpeakIPAText.normalized("A well-known and/or voice_loop fix") == "A well known and or voice loop fix.")
        // Not between letters: left for Kokoro's punctuation.
        #expect(SpeakIPAText.normalized("Wait - what?") == "Wait - what?")
    }

    @Test func commonAbbreviationsAreWrittenOut() {
        #expect(SpeakIPAText.normalized("Use a tool, e.g. grep, i.e. the fast one.")
            == "Use a tool, for example grep, that is the fast one.")
        #expect(SpeakIPAText.normalized("Apples, pears, etc. Then lunch.") == "Apples, pears, et cetera. Then lunch.")
        #expect(SpeakIPAText.normalized("Apples, etc. and pears.") == "Apples, et cetera and pears.")
        #expect(SpeakIPAText.normalized("She said “bring pens, paper, etc.” Then we left.")
            == "She said “bring pens, paper, et cetera.” Then we left.")
        #expect(SpeakIPAText.normalized("Swift vs. Kotlin") == "Swift versus Kotlin.")
        // In capitals, it's more often Visual Studio.
        #expect(SpeakIPAText.normalized("Open VS Code.") == "Open VS Code.")
    }

    @Test func aLineEndingWithACommaOrADashGoesOnIntoTheNext() {
        #expect(SpeakIPAText.normalized("I fixed the parser,\nincluding its tests") == "I fixed the parser,\nincluding its tests.")
        #expect(SpeakIPAText.normalized("Two things —\nthis and that") == "Two things —\nthis and that.")
    }

    @Test func aLineWithoutEndingPunctuationEndsWithAFullStop() {
        #expect(SpeakIPAText.normalized("- First item\n- Second item!\n- Third: (done)") == """
            First item.
            Second item!
            Third: (done).
            """)
        #expect(SpeakIPAText.normalized("He said \"yes.\"") == "He said \"yes.\"")
    }

    @Test func aLineWithNoWordsIsDropped() {
        #expect(SpeakIPAText.normalized("🎉🎉\n---\nDone") == "Done.")
        #expect(SpeakIPAText.normalized("```\ncode only\n```").isEmpty)
    }

    // MARK: - Chunking

    @Test func shortTextIsOneChunk() {
        #expect(SpeakIPAText.chunks(in: "Hello there. How are you?") == ["Hello there. How are you?"])
    }

    @Test func theFirstChunkIsSmallSoItPlaysSoonAndEachLaterOneGrowsByTheGrowthAtMost() {
        let first = "This first sentence is short."
        // 55 characters each.
        let others = (1...6).map { "Sentence number \($0) goes on for a while longer than that." }
        let chunks = SpeakIPAText.chunks(
            in: ([first] + others).joined(separator: " "),
            firstChunkLimit: 40,
            chunkLimit: 130,
            chunkGrowth: 1.5
        )
        // At most 40 characters, then 60, 90, and 130 from then on: each ends with a sentence.
        #expect(chunks == [
            first,
            others[0],
            others[1],
            others[2] + " " + others[3],
            others[4] + " " + others[5],
        ])
    }

    @Test func aShortFirstSentenceStartsTheFirstChunkRatherThanBeingIt() {
        let text = "Done. I pushed the fix to the branch and reran every test, and all of them passed on the very first try."
        let chunks = SpeakIPAText.chunks(in: text)
        // The strongest break in the second half of 80 characters: the comma.
        #expect(chunks == [
            "Done. I pushed the fix to the branch and reran every test,",
            "and all of them passed on the very first try.",
        ])
    }

    @Test func aChunkTakesTheRestIfThatIsAtMostAQuarterOverItsLimit() {
        // 81 characters: one over the first chunk's 80.
        let text = "Two jobs are queued. The nightly finished at three twelve with all tests passing."
        #expect(SpeakIPAText.chunks(in: text) == [text])
        // 106: more than a quarter over.
        let longer = text + " Ship it to everyone now."
        #expect(SpeakIPAText.chunks(in: longer).count == 2)
    }

    @Test func linesAreSentencesOfTheirOwnAndStayLinesInAChunk() {
        let chunks = SpeakIPAText.chunks(in: "First item.\nSecond item.\nThird item.", firstChunkLimit: 20, chunkLimit: 100)
        #expect(chunks == ["First item.", "Second item.\nThird item."])
    }

    @Test func aLowercaseListItemDoesntRunIntoTheLineBefore() {
        let normalized = SpeakIPAText.normalized("- check the build\n- run the tests")
        let chunk = try? #require(SpeakIPAText.chunks(in: normalized).first)
        #expect(chunk == "check the build.\nrun the tests.")
        let transcribed = words([("check", "tʃɛk"), ("the", "ðə"), ("build", "bɪld"), ("run", "rʌn"), ("the", "ðə"), ("tests", "tɛsts")])
        let speech = SpeakIPAText.speech(of: chunk ?? "", transcribed: transcribed, symbols: symbols)
        // The full stop after "build" stays: the line ends there.
        #expect(speech.parts[5] == .text(".\n"))
    }

    @Test func aLongSentenceIsCutAfterClausePunctuationThenBetweenWords() {
        let sentence = "When the build finished, the tests ran; most of them passed quickly and quietly without trouble."
        let chunks = SpeakIPAText.chunks(in: sentence, firstChunkLimit: 30, chunkLimit: 30)
        #expect(chunks == [
            "When the build finished,",
            // "ran;" comes before half of 30 characters: the latest word break instead.
            "the tests ran; most of them",
            "passed quickly and quietly",
            "without trouble.",
        ])
    }

    @Test func aWordLongerThanAChunkIsAChunkOfItsOwn() {
        let chunks = SpeakIPAText.chunks(in: "Say Supercalifragilisticexpialidocious now.", firstChunkLimit: 10, chunkLimit: 10)
        #expect(chunks == ["Say", "Supercalifragilisticexpialidocious", "now."])
    }

    @Test func noTextIsNoChunks() {
        #expect(SpeakIPAText.chunks(in: "").isEmpty)
    }

    // MARK: - Segments

    @Test func aChunkIsWordsAndWhatLiesBetweenThem() {
        #expect(SpeakIPAText.segments(of: "Don't stop, Joaquín!") == [
            .word("Don't"), .other(" "), .word("stop"), .other(", "), .word("Joaquín"), .other("!"),
        ])
        #expect(SpeakIPAText.segments(of: "\"Hi\" (twice)") == [
            .other("\""), .word("Hi"), .other("\" ("), .word("twice"), .other(")"),
        ])
    }

    @Test func anApostropheOutsideAWordIsNotPartOfIt() {
        #expect(SpeakIPAText.words(of: "'Tis the bosses' rule") == ["Tis", "the", "bosses", "rule"])
    }

    @Test func aCombiningMarkStaysWithItsLetter() {
        // e and a combining acute accent.
        #expect(SpeakIPAText.words(of: "cafe\u{0301} au lait") == ["cafe\u{0301}", "au", "lait"])
    }

    // MARK: - The model's IPA

    private func words(_ pairs: [(String, String)]) -> [TranscribedWord] {
        pairs.map { TranscribedWord(word: $0.0, ipa: $0.1) }
    }

    private let symbols = MisakiPhonemes.usSymbols

    @Test func eachWordTakesItsIPAInKokorosNotationAndThePunctuationStays() {
        let speech = SpeakIPAText.speech(
            of: "Hi there, Joaquin.",
            transcribed: words([("Hi", "haɪ"), ("there", "ðɛɹ"), ("Joaquin", "wɑˈkin")]),
            symbols: symbols
        )
        #expect(speech.parts == [
            .phonemes(word: "Hi", phonemes: "hI"), .text(" "),
            .phonemes(word: "there", phonemes: "ðɛɹ"), .text(", "),
            .phonemes(word: "Joaquin", phonemes: "wɑkˈin"), .text("."),
        ])
        #expect(speech.words == 3)
        #expect(speech.wordsWithIPA == 3)
        #expect(speech.usesIPA)
    }

    @Test func wordsMatchWhateverTheirCaseAccentsOrApostrophes() {
        let speech = SpeakIPAText.speech(
            of: "Don't go, Joaquín.",
            transcribed: words([("dont", "doʊnt"), ("GO", "ɡoʊ"), ("Joaquin", "wɑˈkin")]),
            symbols: symbols
        )
        #expect(speech.wordsWithIPA == 3)
        #expect(speech.parts.first == .phonemes(word: "Don't", phonemes: "dOnt"))
    }

    @Test func aWordTheModelSplitGetsTheirIPAAsOneWord() {
        let speech = SpeakIPAText.speech(
            of: "Hello itsybitsy.",
            transcribed: words([("Hello", "həˈloʊ"), ("itsy", "ˈɪtsi"), ("bitsy", "ˈbɪtsi")]),
            symbols: symbols
        )
        // Each stress mark before its vowel, as misaki has them.
        #expect(speech.parts[2] == .phonemes(word: "itsybitsy", phonemes: "ˈɪtsibˈɪtsi"))
        #expect(speech.wordsWithIPA == 2)
    }

    @Test func wordsTheModelJoinedGetItsIPAsWordsIfItHasAsMany() {
        let joined = SpeakIPAText.speech(
            of: "Read this now.",
            transcribed: words([("Read this", "rid ðɪs"), ("now", "naʊ")]),
            symbols: symbols
        )
        #expect(joined.parts == [
            .phonemes(word: "Read", phonemes: "ɹid"), .text(" "),
            .phonemes(word: "this", phonemes: "ðɪs"), .text(" "),
            .phonemes(word: "now", phonemes: "nW"), .text("."),
        ])
        // Two words, one word of IPA: neither can be told apart, so both are said as written.
        let unsplit = SpeakIPAText.speech(
            of: "Read this now.",
            transcribed: words([("Read this", "ridðɪs"), ("now", "naʊ")]),
            symbols: symbols
        )
        #expect(unsplit.parts.prefix(3) == [.text("Read"), .text(" "), .text("this")])
        #expect(unsplit.wordsWithIPA == 1)
        #expect(unsplit.unmatchedWords == 2)
    }

    @Test func aWordTheModelAddedIsSkippedAndOneItLeftOutIsSaidAsWritten() {
        let added = SpeakIPAText.speech(
            of: "Tests passed today.",
            transcribed: words([("Tests", "tɛsts"), ("all", "ɔl"), ("passed", "pæst"), ("today", "təˈdeɪ")]),
            symbols: symbols
        )
        #expect(added.wordsWithIPA == 3)
        #expect(added.parts[2] == .phonemes(word: "passed", phonemes: "pæst"))

        let leftOut = SpeakIPAText.speech(
            of: "Tests really passed today.",
            transcribed: words([("Tests", "tɛsts"), ("passed", "pæst"), ("today", "təˈdeɪ")]),
            symbols: symbols
        )
        #expect(leftOut.parts[2] == .text("really"))
        #expect(leftOut.parts[4] == .phonemes(word: "passed", phonemes: "pæst"))
        #expect(leftOut.wordsWithIPA == 3)
        #expect(leftOut.unmatchedWords == 1)
    }

    @Test func aWordLeftOutIsNotMatchedToALaterWordSpelledTheSame() {
        // "us" left out: "US" comes soon after, but the words after it don't follow.
        let speech = SpeakIPAText.speech(
            of: "Tell us how US rates changed.",
            transcribed: words([("Tell", "tɛl"), ("how", "haʊ"), ("US", "ˌjuˈɛs"), ("rates", "reɪts"), ("changed", "tʃeɪndʒd")]),
            symbols: symbols
        )
        #expect(speech.parts[2] == .text("us"))
        #expect(speech.parts[6] == .phonemes(word: "US", phonemes: "jˌuˈɛs"))
        #expect(speech.wordsWithIPA == 5)
    }

    @Test func aMatchTheWordsAfterBearOutWinsOverOneAtTheEnd() {
        // "record" left out: the last "record" matches it, with nothing after to check; "this
        // record" matches two in a row.
        let record = SpeakIPAText.speech(
            of: "Please record this record.",
            transcribed: words([("Please", "pliz"), ("this", "ðɪs"), ("record", "ˈrɛkɚd")]),
            symbols: symbols
        )
        #expect(record.parts[2] == .text("record"))
        #expect(record.parts[4] == .phonemes(word: "this", phonemes: "ðɪs"))
        #expect(record.parts[6] == .phonemes(word: "record", phonemes: "ɹˈɛkəɹd"))
        // The same with the model's last word as the look-alike.
        let us = SpeakIPAText.speech(
            of: "Show us the US.",
            transcribed: words([("Show", "ʃoʊ"), ("the", "ðə"), ("US", "ˌjuˈɛs")]),
            symbols: symbols
        )
        #expect(us.parts[2] == .text("us"))
        #expect(us.parts[6] == .phonemes(word: "US", phonemes: "jˌuˈɛs"))
    }

    @Test func aWordTheModelSplitIsSaidAsWrittenIfAnyPartHasNoIPAOrIsJustItsSpelling() {
        let empty = SpeakIPAText.speech(
            of: "A worktree.",
            transcribed: words([("A", "ə"), ("work", "wɜrk"), ("tree", "")]),
            symbols: symbols
        )
        #expect(empty.parts[2] == .text("worktree"))
        #expect(empty.emptyWords == 1)
        let echoed = SpeakIPAText.speech(
            of: "A notebook.",
            transcribed: words([("A", "ə"), ("note", "note"), ("book", "bʊk")]),
            symbols: symbols
        )
        #expect(echoed.parts[2] == .text("notebook"))
        #expect(echoed.echoedWords == 1)
    }

    @Test func ipaWithPunctuationIsSaidAsWrittenThoughKokoroHasTheSymbol() {
        // A loaded model's vocabulary has punctuation; in a word's phonemes it would be a pause.
        let speech = SpeakIPAText.speech(of: "Hello", transcribed: words([("Hello", "həˈloʊ!")]), symbols: symbols.union(["!"]))
        #expect(speech.parts == [.text("Hello")])
        #expect(speech.unknownSymbolWords == 1)
    }

    @Test func ofSeveralReadingsTheFirstIsSaid() {
        #expect(SpeakIPAText.firstReading(of: "/ˈiːðər/ /ˈaɪðər/") == "ˈiːðər")
        #expect(SpeakIPAText.firstReading(of: "[ˈiːðər]") == "ˈiːðər")
        #expect(SpeakIPAText.firstReading(of: "ˈiːðər, ˈaɪðər") == "ˈiːðər")
        #expect(SpeakIPAText.firstReading(of: "ˈiːðər or ˈaɪðər") == "ˈiːðər")
        // A space between syllables of one reading stays.
        #expect(SpeakIPAText.firstReading(of: "ˈwɪn stən") == "ˈwɪn stən")
        let speech = SpeakIPAText.speech(of: "either", transcribed: words([("either", "/ˈiːðər/ /ˈaɪðər/")]), symbols: symbols)
        #expect(speech.parts == [.phonemes(word: "either", phonemes: "ˈiðəɹ")])
    }

    @Test func aFullStopThatDoesntEndASentenceGoesWithItsWord() {
        let speech = SpeakIPAText.speech(
            of: "Mr. Smith likes Bach. He plays.",
            transcribed: words([
                ("Mr", "ˈmɪstər"), ("Smith", "smɪθ"), ("likes", "laɪks"), ("Bach", "bɑk"), ("He", "hi"), ("plays", "pleɪz"),
            ]),
            symbols: symbols
        )
        // "Mr." keeps no full stop, which Kokoro would take for a sentence's end; "Bach." keeps its.
        #expect(speech.parts.prefix(3) == [.phonemes(word: "Mr", phonemes: "mˈɪstəɹ"), .text(" "), .phonemes(word: "Smith", phonemes: "smɪθ")])
        #expect(speech.parts[7] == .text(". "))
        #expect(speech.parts.last == .text("."))
        // Said as written, a word's full stop stays: Kokoro reads "Mr." itself.
        let written = SpeakIPAText.speech(of: "Mr. Smith.", transcribed: [], symbols: symbols)
        #expect(written.parts.prefix(2) == [.text("Mr"), .text(". ")])
    }

    @Test func anEllipsisAndADotInsideAWordStay() {
        let speech = SpeakIPAText.speech(
            of: "Well... see README.md now.",
            transcribed: words([("Well", "wɛl"), ("see", "si"), ("README", "ˈrɛdmi"), ("md", "ɛmˈdi"), ("now", "naʊ")]),
            symbols: symbols
        )
        #expect(speech.parts[1] == .text("... "))
        #expect(speech.parts[5] == .text("."))
    }

    @Test func anotherWordInAWordsPlaceIsSaidAsWritten() {
        let speech = SpeakIPAText.speech(
            of: "The colour is red.",
            transcribed: words([("The", "ðə"), ("color", "ˈkʌlɚ"), ("is", "ɪz"), ("red", "rɛd")]),
            symbols: symbols
        )
        #expect(speech.parts[2] == .text("colour"))
        #expect(speech.wordsWithIPA == 3)
    }

    @Test func ipaKokoroCantSayIsSaidAsWritten() {
        // x and ʔ aren't misaki symbols; an empty answer and the word itself are no IPA.
        let speech = SpeakIPAText.speech(
            of: "Bach, uh-oh, why, Kokoro.",
            transcribed: words([("Bach", "bɑx"), ("uh", "ʔʌ"), ("oh", ""), ("why", "waɪ"), ("Kokoro", "kokoro")]),
            symbols: symbols
        )
        #expect(speech.parts[0] == .text("Bach"))
        #expect(speech.unknownSymbolWords == 2)
        #expect(speech.emptyWords == 1)
        #expect(speech.echoedWords == 1)
        #expect(speech.wordsWithIPA == 1)
        // One word of five: the model's answer has gone wrong.
        #expect(!speech.usesIPA)
    }

    @Test func theCheckIsAgainstTheSymbolsKokoroHasNow() {
        let transcribed = words([("Bach", "bɑx")])
        #expect(SpeakIPAText.speech(of: "Bach", transcribed: transcribed, symbols: symbols).wordsWithIPA == 0)
        #expect(SpeakIPAText.speech(of: "Bach", transcribed: transcribed, symbols: symbols.union(["x"])).wordsWithIPA == 1)
    }

    @Test func optionalSoundsAreKept() {
        let speech = SpeakIPAText.speech(of: "Siobhan", transcribed: words([("Siobhan", "ˈʃɪvɔ(h)n")]), symbols: symbols)
        #expect(speech.parts == [.phonemes(word: "Siobhan", phonemes: "ʃˈɪvɔhn")])
    }

    @Test func halfTheWordsWithIPAIsEnoughToSayTheChunkSo() {
        let speech = SpeakIPAText.speech(of: "One two", transcribed: words([("One", "wʌn")]), symbols: symbols)
        #expect(speech.usesIPA)
        #expect(!SpeakIPAText.speech(of: "One two", transcribed: [], symbols: symbols).usesIPA)
    }
}
