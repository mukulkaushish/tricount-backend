import Fluent
import FluentMySQLDriver
import Vapor

extension Application {
    func configureDatabase() throws {
        let hostname = Environment.get("MYSQL_HOST") ?? "127.0.0.1"
        let port = Environment.get("MYSQL_PORT").flatMap(Int.init) ?? 3306
        let username = Environment.get("MYSQL_USERNAME") ?? "tricount"
        let password = Environment.get("MYSQL_PASSWORD") ?? "tricount"
        let database = Environment.get("MYSQL_DATABASE") ?? "tricount"

        databases.use(
            DatabaseConfigurationFactory.mysql(
                hostname: hostname,
                port: port,
                username: username,
                password: password,
                database: database,
                maxConnectionsPerEventLoop: 4
            ),
            as: .mysql
        )
    }
}
