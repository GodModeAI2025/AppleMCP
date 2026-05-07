import Foundation

@main
enum M3MCPBridgeMain {
    static func main() async {
        await MCPServer().run()
    }
}
