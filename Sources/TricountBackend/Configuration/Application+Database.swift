import Fluent
import FluentMySQLDriver
import NIOSSL
import Vapor

extension Application {
    func configureDatabase() throws {
        let configuration = runtimeConfiguration.database

        databases.use(
            DatabaseConfigurationFactory.mysql(
                hostname: configuration.hostname,
                port: configuration.port,
                username: configuration.username,
                password: configuration.password,
                database: configuration.database,
                tlsConfiguration: configuration.tlsConfiguration(),
                maxConnectionsPerEventLoop: configuration.maxConnectionsPerEventLoop
            ),
            as: .mysql
        )
    }
}
