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
        // The next sentence may open with a bracket or a quote.
        #expect(SpeakIPAText.normalized("It reads PDFs, images, etc. (The full list is below.)")
            == "It reads PDFs, images, et cetera. (The full list is below.)")
        #expect(SpeakIPAText.normalized("It prints warnings, errors, etc. “Done” comes last.")
            == "It prints warnings, errors, et cetera. “Done” comes last.")
        #expect(SpeakIPAText.normalized("Swift vs. Kotlin") == "Swift versus Kotlin.")
        // In capitals, it's more often Visual Studio.
        #expect(SpeakIPAText.normalized("Open VS Code.") == "Open VS Code.")
    }

    @Test func aLineEndingWithACommaOrADashGoesOnIntoTheNext() {
        let comma = SpeakIPAText.normalized("I fixed the parser,\nincluding its tests")
        #expect(comma == "I fixed the parser,\nincluding its tests.")
        let dash = SpeakIPAText.normalized("Two things —\nthis and that")
        #expect(dash == "Two things —\nthis and that.")
        // Joined in its chunk, so Kokoro says it as one sentence, not two.
        #expect(SpeakIPAText.chunks(in: comma) == ["I fixed the parser, including its tests."])
        #expect(SpeakIPAText.chunks(in: dash) == ["Two things — this and that."])
        #expect(KokoroText.sentences(in: SpeakIPAText.chunks(in: comma)[0]).count == 1)
        // The comma can be inside a closing quote or bracket.
        let quoted = SpeakIPAText.normalized("“Wait,”\nshe said")
        #expect(quoted == "“Wait,”\nshe said.")
        #expect(SpeakIPAText.chunks(in: quoted) == ["“Wait,” she said."])
        #expect(SpeakIPAText.chunks(in: SpeakIPAText.normalized("Pass a name {name,}\nthen a size")) == ["Pass a name {name,} then a size."])
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
        let chunk = SpeakIPAText.chunks(in: normalized).first ?? ""
        #expect(chunk == "check the build.\nrun the tests.")
        let transcribed = words([("check", "tʃɛk"), ("the", "ðə"), ("build", "bɪld"), ("run", "rʌn"), ("the", "ðə"), ("tests", "tɛsts")])
        let speech = SpeakIPAText.speech(of: chunk, transcribed: transcribed, symbols: symbols)
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
        #expect(speech.changes.isEmpty)
        #expect(speech.wordsWithoutIPA.isEmpty)
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
        // Two words, one word of IPA: they can't be told apart, so they are said together.
        let unsplit = SpeakIPAText.speech(
            of: "Read this now.",
            transcribed: words([("Read this", "ridðɪs"), ("now", "naʊ")]),
            symbols: symbols
        )
        #expect(unsplit.parts == [
            .phonemes(word: "Read this", phonemes: "ɹidðɪs"), .text(" "),
            .phonemes(word: "now", phonemes: "nW"), .text("."),
        ])
        #expect(unsplit.wordsWithIPA == 3)
        #expect(unsplit.wordsWithoutIPA.isEmpty)
        // As for a word the normalizing split: "well-known" is "well known".
        let compound = SpeakIPAText.speech(of: "A well known tool.", transcribed: words([
            ("A", "ə"), ("well-known", "ˌwɛlˈnoʊn"), ("tool", "tul"),
        ]), symbols: symbols)
        #expect(compound.parts[2] == .phonemes(word: "well known", phonemes: "wˌɛlnˈOn"))
        // However many words it joined.
        let fourWords = SpeakIPAText.speech(of: "A state of the art tool.", transcribed: words([
            ("A", "ə"), ("state-of-the-art", "ˌsteɪtəvðiˈɑrt"), ("tool", "tul"),
        ]), symbols: symbols)
        #expect(fourWords.parts[2] == .phonemes(word: "state of the art", phonemes: "stˌAtəvðiˈɑɹt"))
        #expect(fourWords.wordsWithIPA == 6)
        // Each word's own slashes part them, as spaces do.
        let slashed = SpeakIPAText.speech(of: "Read this now.", transcribed: words([
            ("Read this", "/rid/ /ðɪs/"), ("now", "naʊ"),
        ]), symbols: symbols)
        #expect(slashed.parts.prefix(3) == [.phonemes(word: "Read", phonemes: "ɹid"), .text(" "), .phonemes(word: "this", phonemes: "ðɪs")])
        // Readings of them all: the first, then its words.
        #expect(SpeakIPAText.joinedReadingWords(of: "/rid/ /ðɪs/ or /rɛd/ /ðɪs/") == ["rid", "ðɪs"])
        #expect(SpeakIPAText.joinedReadingWords(of: "/rid/ /ðɪs/,") == ["rid", "ðɪs,"])
        #expect(SpeakIPAText.joinedReadingWords(of: "/rid ðɪs/ (or /rɛd ðɪs/)") == ["rid", "ðɪs"])
        let bracketedOr = SpeakIPAText.speech(of: "Read this now.", transcribed: words([
            ("Read this", "/rid ðɪs/ (or /rɛd ðɪs/)"), ("now", "naʊ"),
        ]), symbols: symbols)
        #expect(bracketedOr.parts.prefix(3) == [.phonemes(word: "Read", phonemes: "ɹid"), .text(" "), .phonemes(word: "this", phonemes: "ðɪs")])
        // Fewer words of IPA than words: all of it, said together.
        let city = SpeakIPAText.speech(of: "New York City.", transcribed: words([("New York City", "/nuˈjɔɹk/ /ˈsɪti/")]), symbols: symbols)
        #expect(city.parts.first == .phonemes(word: "New York City", phonemes: "nujˈɔɹksˈɪti"))
        // Of two readings, the first, before it is split word by word.
        let readings = SpeakIPAText.speech(of: "A data base.", transcribed: words([
            ("A", "ə"), ("database", "ˈdeɪtəbeɪs, ˈdætəbeɪs"),
        ]), symbols: symbols)
        #expect(readings.parts[2] == .phonemes(word: "data base", phonemes: "dˈAtəbAs"))
        // With no sound in its IPA, each word is counted.
        let silent = SpeakIPAText.speech(of: "A well known tool.", transcribed: words([
            ("A", "ə"), ("well-known", ""), ("tool", "tul"),
        ]), symbols: symbols)
        #expect(silent.wordsWithNothingToSay == ["well", "known"])
        // With punctuation between, which said together would go, there is no IPA for them.
        let punctuated = SpeakIPAText.speech(
            of: "Read, this now.",
            transcribed: words([("Read this", "ridðɪs"), ("now", "naʊ")]),
            symbols: symbols
        )
        #expect(punctuated.parts.prefix(3) == [.text("Read"), .text(", "), .text("this")])
        #expect(punctuated.wordsWithoutIPA == ["Read", "this"])
    }

    @Test func aWordTheModelAddedIsSkippedAndOneItLeftOutIsSaidAsKokoroReadsIt() {
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
        #expect(leftOut.wordsWithoutIPA == ["really"])

        // Two left out, a word apart: "like" is still found, though the word after it differs.
        let twoLeftOut = SpeakIPAText.speech(
            of: "We really like good coffee.",
            transcribed: words([("We", "wi"), ("like", "laɪk"), ("coffee", "ˈkɔfi")]),
            symbols: symbols
        )
        #expect(twoLeftOut.parts[4] == .phonemes(word: "like", phonemes: "lIk"))
        #expect(twoLeftOut.wordsWithoutIPA == ["really", "good"])
    }

    @Test func anotherWordInAWordsPlaceDoesntSendTheMatchToALaterLookAlike() {
        // "A" for "One": the words after are in step at once, so the later "a" isn't taken.
        let speech = SpeakIPAText.speech(
            of: "One step at a time.",
            transcribed: words([("A", "ə"), ("step", "stɛp"), ("at", "æt"), ("a", "ə"), ("time", "taɪm")]),
            symbols: symbols
        )
        #expect(speech.wordsWithoutIPA == ["One"])
        #expect(speech.wordsWithIPA == 4)
        let file = SpeakIPAText.speech(
            of: "Select a file in a folder.",
            transcribed: words([("Select", "sɪˈlɛkt"), ("the", "ðə"), ("file", "faɪl"), ("in", "ɪn"), ("a", "ə"), ("folder", "ˈfoʊldɚ")]),
            symbols: symbols
        )
        #expect(file.wordsWithoutIPA == ["a"])
        #expect(file.parts[4] == .phonemes(word: "file", phonemes: "fIl"))
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

    @Test func aWordTheModelSplitIsSaidFromWhatIPAItHasWhateverItIs() {
        // Always the model's IPA: a part with none, or just its spelling, is said as it is.
        let empty = SpeakIPAText.speech(
            of: "A worktree.",
            transcribed: words([("A", "ə"), ("work", "wɜrk"), ("tree", "")]),
            symbols: symbols
        )
        #expect(empty.parts[2] == .phonemes(word: "worktree", phonemes: "wɜɹk"))
        let echoed = SpeakIPAText.speech(
            of: "A notebook.",
            transcribed: words([("A", "ə"), ("note", "note"), ("book", "bʊk")]),
            symbols: symbols
        )
        #expect(echoed.parts[2] == .phonemes(word: "notebook", phonemes: "nOtɛbʊk"))
    }

    @Test func punctuationInAWordsIPAIsLeftOutThoughKokoroHasTheSymbol() {
        // A loaded model's vocabulary has punctuation; in a word's phonemes it would be a pause.
        let speech = SpeakIPAText.speech(of: "Hello", transcribed: words([("Hello", "həˈloʊ!")]), symbols: symbols.union(["!"]))
        #expect(speech.parts == [.phonemes(word: "Hello", phonemes: "həlˈO")])
        #expect(speech.changes == [.init(word: "Hello", from: "!", to: "")])
    }

    @Test func ofSeveralReadingsTheFirstIsSaid() {
        #expect(SpeakIPAText.firstReading(of: "/ˈiːðər/ /ˈaɪðər/") == "ˈiːðər")
        #expect(SpeakIPAText.firstReading(of: "[ˈiːðər]") == "ˈiːðər")
        #expect(SpeakIPAText.firstReading(of: "ˈiːðər, ˈaɪðər") == "ˈiːðər")
        #expect(SpeakIPAText.firstReading(of: "ˈiːðər or ˈaɪðər") == "ˈiːðər")
        #expect(SpeakIPAText.firstReading(of: "ˈiːðər (or ˈaɪðər)") == "ˈiːðər")
        // A comma after the only reading isn't a list: it stays, to be left out and recorded.
        #expect(SpeakIPAText.firstReading(of: "həˈloʊ,") == "həˈloʊ,")
        #expect(SpeakIPAText.firstReading(of: "/həˈloʊ/,") == "həˈloʊ,")
        #expect(SpeakIPAText.firstReading(of: "“/həˈloʊ/”") == "“həˈloʊ”")
        #expect(SpeakIPAText.firstReading(of: "“/həˈloʊ/,”") == "“həˈloʊ,”")
        // No reading at all: its punctuation, to be recorded as left out.
        #expect(SpeakIPAText.firstReading(of: "—") == "—")
        // A bar beside the only reading is no reading of its own.
        #expect(SpeakIPAText.firstReading(of: "/həˈloʊ/ |") == "həˈloʊ |")
        #expect(SpeakIPAText.firstReading(of: "| /həˈloʊ/") == "| həˈloʊ")
        #expect(SpeakIPAText.firstReading(of: "/ˈiːðər/, /ˈaɪðər/") == "ˈiːðər")
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

    @Test func anotherWordInAWordsPlaceIsNoIPAForIt() {
        let speech = SpeakIPAText.speech(
            of: "The colour is red.",
            transcribed: words([("The", "ðə"), ("color", "ˈkʌlɚ"), ("is", "ɪz"), ("red", "rɛd")]),
            symbols: symbols
        )
        #expect(speech.parts[2] == .text("colour"))
        #expect(speech.wordsWithIPA == 3)
        #expect(speech.wordsWithoutIPA == ["colour"])
    }

    @Test func everyWordIsSaidFromItsIPAWithSymbolsKokoroLacksPutAsTheClosestAndRecorded() {
        // x and ʔ aren't misaki symbols: x is put as k, and ʔ, with nothing close, left out. The
        // word itself as its "IPA" is still said from it; an empty answer has no sound to say.
        let speech = SpeakIPAText.speech(
            of: "Bach, uh-oh, why, Kokoro.",
            transcribed: words([("Bach", "bɑx"), ("uh", "ʔʌ"), ("oh", ""), ("why", "waɪ"), ("Kokoro", "kokoro")]),
            symbols: symbols
        )
        #expect(speech.parts[0] == .phonemes(word: "Bach", phonemes: "bɑk"))
        #expect(speech.parts[2] == .phonemes(word: "uh", phonemes: "ʌ"))
        #expect(speech.parts[4] == .text("oh"))
        #expect(speech.parts[8] == .phonemes(word: "Kokoro", phonemes: "kOkɔɹO"))
        #expect(speech.changes == [.init(word: "Bach", from: "x", to: "k"), .init(word: "uh", from: "ʔ", to: "")])
        #expect(speech.wordsWithNothingToSay == ["oh"])
        #expect(speech.wordsWithIPA == 4)
    }

    @Test func theStressGoesBeforeAVowelKokoroLacksBeforeItIsPutAsTheClosest() {
        let speech = SpeakIPAText.speech(of: "Müller", transcribed: words([("Müller", "ˈmʏlɐ")]), symbols: symbols)
        #expect(speech.parts == [.phonemes(word: "Müller", phonemes: "mˈʊlə")])
        #expect(speech.changes == [.init(word: "Müller", from: "ʏ", to: "ʊ")])
    }

    @Test func theSymbolsCheckedAreTheOnesKokoroHasNow() {
        let transcribed = words([("Bach", "bɑx")])
        #expect(SpeakIPAText.speech(of: "Bach", transcribed: transcribed, symbols: symbols).parts == [.phonemes(word: "Bach", phonemes: "bɑk")])
        let withX = SpeakIPAText.speech(of: "Bach", transcribed: transcribed, symbols: symbols.union(["x"]))
        #expect(withX.parts == [.phonemes(word: "Bach", phonemes: "bɑx")])
        #expect(withX.changes.isEmpty)
    }

    @Test func aWordWhoseIPAIsOnlyMarksHasNoSoundAndIsSaidAsKokoroReadsIt() {
        let speech = SpeakIPAText.speech(of: "Hm", transcribed: words([("Hm", "ˈʔ")]), symbols: symbols)
        #expect(speech.parts == [.text("Hm")])
        #expect(speech.wordsWithNothingToSay == ["Hm"])
        #expect(speech.changes == [.init(word: "Hm", from: "ʔ", to: "")])
    }

    @Test func optionalSoundsAreKept() {
        let speech = SpeakIPAText.speech(of: "Siobhan", transcribed: words([("Siobhan", "ˈʃɪvɔ(h)n")]), symbols: symbols)
        #expect(speech.parts == [.phonemes(word: "Siobhan", phonemes: "ʃˈɪvɔhn")])
    }

    @Test func noWordsFromTheModelLeavesEveryWordWithoutIPA() {
        let speech = SpeakIPAText.speech(of: "One two", transcribed: [], symbols: symbols)
        #expect(speech.parts == [.text("One"), .text(" "), .text("two")])
        #expect(speech.wordsWithoutIPA == ["One", "two"])
    }
}
