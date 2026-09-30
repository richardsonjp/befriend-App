import Foundation
import Testing
@testable import PetCore

struct MarkdownTests {
    static let sample = """
        Oh, I see you're diving into **deep** stuff!

        ### Summary:
        - **Issue Overview**: The backend refuses to unbind.
        - Nested:
          - inner one
        1. First
        2. Second

        > A quote.

        ```bash
        git status
        echo "hi"
        ```

        | Name | Age |
        |------|-----|
        | Mochi | 3 |
        | Tom | 5 |

        ```mermaid
        graph TD; A-->B
        ```
        Done.
        """

    @Test func blocksComeOutInOrder() {
        let blocks = MarkdownBlock.parse(Self.sample)
        let kinds = blocks.map(\.kind)
        #expect(kinds.first == .paragraph)
        #expect(kinds.contains(.heading(3)))
        #expect(kinds.contains(.listItem(depth: 1, marker: "•")))
        #expect(kinds.contains(.listItem(depth: 2, marker: "•")))
        #expect(kinds.contains(.listItem(depth: 1, marker: "2.")))
        #expect(kinds.contains(.quote))
        let bash = blocks.first { $0.kind == .code(language: "bash") }
        #expect(bash?.plain == "git status\necho \"hi\"")
        #expect(blocks.contains { $0.kind == .code(language: "mermaid") })
        guard case .table(let rows)? = blocks.first(where: { if case .table = $0.kind { true } else { false } })?.kind else {
            Issue.record("no table"); return
        }
        #expect(rows.map { $0.map { String($0.characters) } } == [["Name", "Age"], ["Mochi", "3"], ["Tom", "5"]])
        #expect(blocks.last.map { String($0.text.characters) } == "Done.")
    }

    @Test func boldStaysInline() {
        let first = MarkdownBlock.parse("Hi **there**")[0]
        #expect(String(first.text.characters) == "Hi there")
        #expect(first.text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    @Test func aTrailingTableIsKept() {
        #expect(MarkdownBlock.parse("| a | b |\n|---|---|\n| 1 | 2 |").count == 1)
    }

    @Test func unfinishedCodeWhileStreaming() {
        #expect(MarkdownBlock.parse("```python\nprint(1)").first?.kind == .code(language: "python"))
    }
}
