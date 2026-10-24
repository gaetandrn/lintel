import Testing
@testable import LintelCore

struct CallsTests {
    @Test func helperBelongsToItsApp() {
        let apps = ["com.microsoft.teams2", "com.apple.finder", "com.example.browser"]
        #expect(appOwning(audioProcess: "com.microsoft.teams2.modulehost", among: apps) == "com.microsoft.teams2")
        #expect(appOwning(audioProcess: "com.example.browser", among: apps) == "com.example.browser")
        #expect(appOwning(audioProcess: "com.apple.CoreSpeech", among: apps) == nil)
        // Prefix not on a dot boundary.
        #expect(appOwning(audioProcess: "com.microsoft.teams2x", among: apps) == nil)
    }

    @Test func compactViewNamesTheCallWindow() {
        let windows = [
            WindowTitle(title: "Meeting compact view | Meeting with Alex Martin", isStandard: false),
            WindowTitle(title: "Meeting with Alex Martin", isStandard: true),
            WindowTitle(title: "Calendar", isStandard: true),
        ]
        #expect(callWindowTitle(windows) == "Meeting with Alex Martin")
    }

    @Test func titleWhenNoCompactView() {
        let windows = [WindowTitle(title: "Chat | Design", isStandard: true), WindowTitle(title: "Réunion avec Alex", isStandard: true)]
        #expect(callWindowTitle(windows) == "Réunion avec Alex")
    }

    @Test func mainWindowSeparatorIsNotACall() {
        // A standard window's " | " is just part of its title.
        let windows = [WindowTitle(title: "Chat | Design", isStandard: true), WindowTitle(title: "Calendar", isStandard: true)]
        #expect(callWindowTitle(windows) == nil)
    }

    @Test func otherAppsCallWindows() {
        #expect(callWindowTitle([WindowTitle(title: "Zoom Meeting", isStandard: true)]) == "Zoom Meeting")
        #expect(callWindowTitle([WindowTitle(title: "Meet - abc-defg-hij", isStandard: true)]) == "Meet - abc-defg-hij")
    }

    @Test(arguments: ["Meet - abc", "Zoom Meeting", "Réunion avec Alex", "Appel en cours", "TEAMS CALL", "L'appel"])
    func keywordsMatchAsWholeWords(title: String) {
        #expect(callWindowTitle([WindowTitle(title: title, isStandard: true)]) == title)
    }

    @Test(arguments: ["Callback", "Meetup", "Recall", "Appellation", "Meetings archive"])
    func keywordsInsideOtherWordsDoNotMatch(title: String) {
        #expect(callWindowTitle([WindowTitle(title: title, isStandard: true)]) == nil)
    }

    @Test func mainWindowAloneIsNotTheCall() {
        // End of a Teams call: the call window is gone, the microphone not yet released.
        #expect(callWindowTitle([WindowTitle(title: "Calendar", isStandard: true)]) == nil)
    }
}
