/// A tester's dictation exactly as version 1.3 inserted it: glued segments, misheard names,
/// unresolved self-corrections, no structure. Fixture for the tests and the "Pipeline testen" window.
enum Fixture {
    static let testerFeedback = "guten Morgen Colin, wie besprochen hier mein kurzes Feedback zu Colin Whisper, welches ich mit Colin Wis.per aufnehme.Ich finde die Lösung sehr gut und sehr angenehm im direkten Vergleich mit dem US. WhisperFällt mir lediglich auf, dass das US Whisper teilweise den Nicht Satzbau, sondern die Art und Weise. Zeilenumbrüche, Bullet Points automatisch gesetzte Fragezeichen umsetzt beziehungsweise. besser umsetzt beziehungsweise Colin Whisper Zeilenumbrüche und Bullet Points nicht macht. Das ist tatsächlich das einzige Feedback. Ich habe das Update DeployedLäuft einwandfrei und smooth as Fuck.MFG Louis W."

    /// The same dictation as SpeechTranscriber segments. Glued without a separator they give
    /// `testerFeedback`; some start with a space, as real segments often do.
    static let testerFeedbackSegments = [
        "guten Morgen Colin, wie besprochen hier mein kurzes Feedback zu Colin Whisper, welches ich mit Colin Wis.per aufnehme.",
        "Ich finde die Lösung sehr gut und sehr angenehm im direkten Vergleich mit dem US. Whisper",
        "Fällt mir lediglich auf, dass das US Whisper teilweise den Nicht Satzbau, sondern die Art und Weise. Zeilenumbrüche, Bullet Points automatisch gesetzte Fragezeichen umsetzt beziehungsweise.",
        " besser umsetzt beziehungsweise Colin Whisper Zeilenumbrüche und Bullet Points nicht macht.",
        " Das ist tatsächlich das einzige Feedback. Ich habe das Update Deployed",
        "Läuft einwandfrei und smooth as Fuck.",
        "MFG Louis W.",
    ]
}
