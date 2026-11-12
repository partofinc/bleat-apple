#if DEBUG
import BleatKit
import Foundation

/// herdr-core terminals for previews, shaped like the live records in
/// `Fixtures/hc-subscribe.json` (a preview cannot read the fixtures, which are
/// not in the app bundle).
extension HcTerminal {
    static var samples: [HcTerminal] {
        decode("""
        [
          {"address":"t58","title":"Backend","state":"live","turn":16,
           "cwd":"/Users/robin/Developer/backend",
           "status":{"app":"claude-code","msg":"Needs approval to run the migration","state":"blocked","reason":"permission"},
           "labels":{"where":"backend / Agent","herdr.seen":"15"}},
          {"address":"t59","title":"Apple app","state":"live","turn":4,
           "status":{"app":"claude-code","msg":"Fixed the date picker on iPad","state":"done"},
           "labels":{"where":"apple / Agent","herdr.seen":"3"}},
          {"address":"t5b","title":"Android app","state":"live","turn":22,
           "status":{"app":"claude-code","msg":"Running the instrumented tests","state":"working","progress":40},
           "labels":{"where":"android / 1","herdr.seen":"21"}},
          {"address":"t5c","title":"Platform","state":"live","turn":9,
           "status":{"app":"claude-code","msg":"Released 2.3.1","state":"done"},
           "labels":{"where":"backend / Agent","herdr.seen":"9"}},
          {"address":"t5d","title":"","name":"links","state":"live",
           "cwd":"/Users/robin/Developer/links","foreground":{"argv":["zsh"]},
           "status":{"state":"idle"},"labels":{"where":"links / 1"}},
          {"address":"t5e","title":"","state":"live","argv":["/bin/zsh"],
           "cwd":"/Users/robin","status":{"state":"error","msg":"Login expired"},
           "labels":{"where":"links / 2"}}
        ]
        """)
    }

    /// A Pi: no Herdr.app, so no `where` labels and no spaces.
    static var samplesWithoutSpaces: [HcTerminal] {
        decode("""
        [
          {"address":"t8","title":"Indexer","state":"live","turn":2,
           "status":{"app":"claude-code","msg":"Rebuilding the index","state":"working"}},
          {"address":"t9","state":"live","argv":["htop"],"cwd":"/home/pi"},
          {"address":"t10","state":"live","argv":["/bin/bash"],"cwd":"/home/pi","status":null}
        ]
        """)
    }

    private static func decode(_ json: String) -> [HcTerminal] {
        (try? JSONDecoder().decode([HcTerminal].self, from: Data(json.utf8))) ?? []
    }
}
#endif
