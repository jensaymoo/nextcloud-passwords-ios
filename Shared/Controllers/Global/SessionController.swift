import SwiftUI
import Combine


final class SessionController: ObservableObject {
    
    static let `default` = SessionController()
    
    @Published var session: Session? {
        didSet {
            guard let session = session else {
                Keychain.default.remove(key: "server")
                Keychain.default.remove(key: "user")
                Keychain.default.remove(key: "password")
                challengeAvailable = false
                error = false
                challenge = nil
                cachedChallengePassword = nil
                subscriptions.removeAll()
                Keychain.default.remove(key: "challengePassword")
                Keychain.default.remove(key: "offlineKeychain")
                return
            }
            Keychain.default.store(key: "server", value: session.server)
            Keychain.default.store(key: "user", value: session.user)
            Keychain.default.store(key: "password", value: session.password)
            
            session.$pendingRequestsAvailable
                .sink {
                    [weak self] pendingRequestsAvailable in
                    if pendingRequestsAvailable {
                        self?.requestSession()
                    }
                }
                .store(in: &subscriptions)
            session.$pendingCompletionsAvailable
                .sink {
                    [weak self] pendingCompletionsAvailable in
                    if pendingCompletionsAvailable {
                        self?.requestKeychain()
                    }
                }
                .store(in: &subscriptions)
            session.$invalidationReason
                .sink {
                    [weak self] invalidationReason in
                    guard let invalidationReason = invalidationReason else {
                        return
                    }
                    self?.session = nil
                    if invalidationReason == .deauthorization {
                        AuthenticationChallengeController.default.clearAcceptedCertificateHash()
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
                            UIAlertController.presentGlobalAlert(title: "_appDeauthorized".localized, message: "_appDeauthorizedMessage".localized)
                        }
                    }
                }
                .store(in: &subscriptions)
        }
    }
    @Published private(set) var challengeAvailable = false
    @Published private(set) var error = false
    
    private var challenge: Crypto.PWDv1r1.Challenge?
    private var cachedChallengePassword: String? {
        willSet {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(15)) {
                [weak self] in
                guard newValue == self?.cachedChallengePassword else {
                    return
                }
                self?.cachedChallengePassword = nil
            }
        }
    }
    private var keepaliveTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    
    private init() {
        guard let server = Keychain.default.load(key: "server"),
              let user = Keychain.default.load(key: "user"),
              let password = Keychain.default.load(key: "password") else {
            return
        }
        session = Session(server: server, user: user, password: password)
    }
    
    private init(session: Session) {
        self.session = session
    }
    
    private func requestSession() {
        guard let session = session else {
            return
        }
        
        session.sessionID = nil
        
        RequestSessionRequest(session: session).send {
            [weak self] response in
            guard let response = response else {
                self?.error = true
                return
            }
            
            guard let challenge = response.challenge else {
                self?.openSession()
                return
            }
            self?.challenge = challenge
            self?.challengeAvailable = true
            
            if let challengePassword = Keychain.default.load(key: "challengePassword") ?? self?.cachedChallengePassword {
                self?.solveChallenge(password: challengePassword)
            }
        }
    }
    
    private func requestKeychain() {
        guard let session = session else {
            return
        }
        
        guard session.keychain == nil,
              Keychain.default.load(key: "offlineKeychain") != nil else {
            session.runPendingCompletions()
            return
        }
        
        challengeAvailable = true
        
        if let challengePassword = Keychain.default.load(key: "challengePassword") ?? cachedChallengePassword {
            solveChallenge(password: challengePassword)
        }
    }
    
    func solveChallenge(password: String, store: Bool = false) {
        guard let session = session else {
            error = true
            return
        }
        
        challengeAvailable = false
        
        if let challenge = challenge {
            guard let solution = Crypto.PWDv1r1.solve(challenge: challenge, password: password) else {
                error = true
                return
            }
            openSession(password: password, solution: solution, store: store)
        }
        else if let offlineKeychain = Keychain.default.load(key: "offlineKeychain") {
            guard let keychain = Crypto.CSEv1r1.decrypt(keys: offlineKeychain, password: password) else {
                challengeAvailable = true
                Keychain.default.remove(key: "challengePassword")
                UIAlertController.presentGlobalAlert(title: "_incorrectPassword".localized, message: "_incorrectPasswordMessage".localized)
                return
            }
            session.keychain = keychain
            cachedChallengePassword = password
            if store {
                Keychain.default.store(key: "challengePassword", value: password)
            }
            
            session.runPendingCompletions()
        }
    }
    
    private func openSession(password: String? = nil, solution: String? = nil, store: Bool? = nil) {
        guard let session = session else {
            return
        }
        
        OpenSessionRequest(session: session, solution: solution).send {
            [weak self] response in
            guard let response = response else {
                self?.error = true
                return
            }
            
            if let password = password,
               solution != nil,
               let store = store {
                guard response.success,
                      let keys = response.keys["CSEv1r1"] else {
                    self?.challengeAvailable = true
                    Keychain.default.remove(key: "challengePassword")
                    UIAlertController.presentGlobalAlert(title: "_incorrectPassword".localized, message: "_incorrectPasswordMessage".localized)
                    return
                }
                Keychain.default.store(key: "offlineKeychain", value: keys)
                let keychain = Crypto.CSEv1r1.decrypt(keys: keys, password: password)
                session.keychain = keychain
                self?.cachedChallengePassword = password
                if store {
                    Keychain.default.store(key: "challengePassword", value: password)
                }
            }
            else {
                guard response.success else {
                    self?.error = true
                    return
                }
            }
            
            self?.keepaliveSession()
            
            session.runPendingRequests()
        }
    }
    
    private func keepaliveSession() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 9 * 60, repeats: false) {
            [weak self] _ in
            guard let session = self?.session else {
                return
            }
            KeepaliveSessionRequest(session: session).send {
                [weak self] response in
                guard let response = response,
                      response.success else {
                    return
                }
                self?.keepaliveSession()
            }
        }
    }
    
    func logout() {
        guard let session = session else {
            return
        }
        CloseSessionRequest(session: session).send { _ in AuthenticationChallengeController.default.clearAcceptedCertificateHash() }
        session.invalidate(reason: .logout)
    }
    
}


extension SessionController: MockObject {
    
    static var mock: SessionController {
        SessionController(session: Session.mock)
    }
    
}
