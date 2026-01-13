import XCTest
@testable import MoneroOne

@MainActor
final class NodeManagerTests: XCTestCase {

    var nodeManager: NodeManager!

    override func setUp() async throws {
        // Clear any saved state
        UserDefaults.standard.removeObject(forKey: "selectedNodeURL")
        UserDefaults.standard.removeObject(forKey: "customNodes")
        nodeManager = NodeManager()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "selectedNodeURL")
        UserDefaults.standard.removeObject(forKey: "customNodes")
        nodeManager = nil
    }

    // MARK: - Default Nodes Tests

    func testDefaultNodesExist() {
        XCTAssertFalse(NodeManager.defaultNodes.isEmpty, "Should have default nodes")
        XCTAssertGreaterThanOrEqual(NodeManager.defaultNodes.count, 3, "Should have at least 3 default nodes")
    }

    func testDefaultNodesHaveValidURLs() {
        for node in NodeManager.defaultNodes {
            XCTAssertFalse(node.url.isEmpty, "Node URL should not be empty")
            XCTAssertNotNil(URL(string: node.url), "Node URL should be valid: \(node.url)")
            XCTAssertTrue(node.url.hasPrefix("https://"), "Node URL should use HTTPS: \(node.url)")
        }
    }

    func testDefaultNodesHaveNames() {
        for node in NodeManager.defaultNodes {
            XCTAssertFalse(node.name.isEmpty, "Node should have a name")
        }
    }

    // MARK: - Node Selection Tests

    func testInitialSelectedNodeIsFirstDefault() {
        let firstDefault = NodeManager.defaultNodes[0]
        XCTAssertEqual(nodeManager.selectedNode.url, firstDefault.url, "Initial selection should be first default node")
    }

    func testSelectNodeUpdatesSelection() {
        let secondNode = NodeManager.defaultNodes[1]
        nodeManager.selectNode(secondNode)

        XCTAssertEqual(nodeManager.selectedNode.url, secondNode.url, "Selected node should be updated")
    }

    func testSelectNodePersistsToUserDefaults() {
        let secondNode = NodeManager.defaultNodes[1]
        nodeManager.selectNode(secondNode)

        let savedURL = UserDefaults.standard.string(forKey: "selectedNodeURL")
        XCTAssertEqual(savedURL, secondNode.url, "Selection should be persisted to UserDefaults")
    }

    func testSelectionPersistsAcrossInstances() {
        let secondNode = NodeManager.defaultNodes[1]
        nodeManager.selectNode(secondNode)

        // Create new instance
        let newManager = NodeManager()
        XCTAssertEqual(newManager.selectedNode.url, secondNode.url, "Selection should persist across instances")
    }

    // MARK: - Custom Node Tests

    func testAddCustomNode() {
        let customURL = "https://custom.node.com:18081"
        let customName = "My Custom Node"

        nodeManager.addCustomNode(name: customName, url: customURL)

        XCTAssertEqual(nodeManager.customNodes.count, 1, "Should have 1 custom node")
        XCTAssertEqual(nodeManager.customNodes[0].name, customName)
        XCTAssertEqual(nodeManager.customNodes[0].url, customURL)
    }

    func testRemoveCustomNode() {
        nodeManager.addCustomNode(name: "Test", url: "https://test.com:18081")
        let addedNode = nodeManager.customNodes[0]

        nodeManager.removeCustomNode(addedNode)

        XCTAssertTrue(nodeManager.customNodes.isEmpty, "Custom nodes should be empty after removal")
    }

    func testRemoveSelectedCustomNodeSwitchesToDefault() {
        let customURL = "https://custom.node.com:18081"
        nodeManager.addCustomNode(name: "Custom", url: customURL)
        let customNode = nodeManager.customNodes[0]

        nodeManager.selectNode(customNode)
        nodeManager.removeCustomNode(customNode)

        XCTAssertEqual(nodeManager.selectedNode.url, NodeManager.defaultNodes[0].url,
                       "Should switch to default node when selected custom node is removed")
    }

    func testCustomNodesPersistAcrossInstances() {
        nodeManager.addCustomNode(name: "Persistent", url: "https://persistent.com:18081")

        let newManager = NodeManager()
        XCTAssertEqual(newManager.customNodes.count, 1, "Custom nodes should persist")
        XCTAssertEqual(newManager.customNodes[0].name, "Persistent")
    }

    // MARK: - Connection Status Tests

    func testInitialConnectionStatusIsUnknown() {
        XCTAssertEqual(nodeManager.connectionStatus, .unknown, "Initial status should be unknown")
    }
}
