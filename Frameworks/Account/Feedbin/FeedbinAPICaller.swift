//
//  FeedbinAPICaller.swift
//  Account
//
//  Created by Maurice Parker on 5/2/19.
//  Copyright © 2019 Ranchero Software, LLC. All rights reserved.
//

// Feedbin currently has a maximum of 250 requests per second.  If you begin to receive
// HTTP Response Codes of 403, you have exceeded this limit.  Wait 5 minutes and your
// IP address will become unblocked and you can use the service again.

import Foundation
import RSWeb

enum CreateSubscriptionResult {
	case created(FeedbinSubscription)
	case multipleChoice([FeedbinSubscriptionChoice])
	case alreadySubscribed
	case notFound
}

final class FeedbinAPICaller: NSObject {
	
	struct ConditionalGetKeys {
		static let subscriptions = "subscriptions"
		static let tags = "tags"
		static let taggings = "taggings"
		static let icons = "icons"
		static let unreadEntries = "unreadEntries"
		static let starredEntries = "starredEntries"
	}
	
	private let feedbinBaseURL = URL(string: "https://api.feedbin.com/v2/")!
	private var transport: Transport!
	
	var credentials: Credentials?
	var accountMetadata: AccountMetadata?

	init(transport: Transport) {
		super.init()
		self.transport = transport
	}
	
	func validateCredentials(completionHandler completion: @escaping (Result<Bool, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("authentication.json")
		let request = URLRequest(url: callURL, credentials: credentials)
		
		transport.send(request: request) { result in
			switch result {
			case .success:
				completion(.success(true))
			case .failure(let error):
				switch error {
				case TransportError.httpError(let status):
					if status == 401 {
						completion(.success(false))
					} else {
						completion(.failure(error))
					}
				default:
					completion(.failure(error))
				}
			}
		}
		
	}
	
	func retrieveTags(completionHandler completion: @escaping (Result<[FeedbinTag]?, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("tags.json")
		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.tags]
		let request = URLRequest(url: callURL, credentials: credentials, conditionalGet: conditionalGet)

		transport.send(request: request, resultType: [FeedbinTag].self) { [weak self] result in
			
			switch result {
			case .success(let (response, tags)):
				self?.storeConditionalGet(key: ConditionalGetKeys.tags, headers: response.allHeaderFields)
				completion(.success(tags))
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}

	func renameTag(oldName: String, newName: String, completion: @escaping (Result<Void, Error>) -> Void) {
		let callURL = feedbinBaseURL.appendingPathComponent("tags.json")
		let request = URLRequest(url: callURL, credentials: credentials)
		let payload = FeedbinRenameTag(oldName: oldName, newName: newName)
		transport.send(request: request, method: HTTPMethod.post, payload: payload, completion: completion)
	}
	
	func deleteTag(name: String, completion: @escaping (Result<[FeedbinTagging]?, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("tags.json")
		let request = URLRequest(url: callURL, credentials: credentials)
		let payload = FeedbinDeleteTag(name: name)
		
		transport.send(request: request, method: HTTPMethod.delete, payload: payload, resultType: [FeedbinTagging].self) { result in

			switch result {
			case .success(let (_, taggings)):
				completion(.success(taggings))
			case .failure(let error):
				completion(.failure(error))
			}

		}
		
	}
	
	func retrieveSubscriptions(completionHandler completion: @escaping (Result<[FeedbinSubscription]?, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("subscriptions.json")
		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.subscriptions]
		let request = URLRequest(url: callURL, credentials: credentials, conditionalGet: conditionalGet)
		
		transport.send(request: request, resultType: [FeedbinSubscription].self) { [weak self] result in
			
			switch result {
			case .success(let (response, subscriptions)):
				self?.storeConditionalGet(key: ConditionalGetKeys.subscriptions, headers: response.allHeaderFields)
				completion(.success(subscriptions))
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}
	
	func createSubscription(url: String, completionHandler completion: @escaping (Result<CreateSubscriptionResult, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("subscriptions.json")
		var request = URLRequest(url: callURL, credentials: credentials)
		request.addValue("application/json; charset=utf-8", forHTTPHeaderField: HTTPRequestHeader.contentType)
		
		let payload: Data
		do {
			payload = try JSONEncoder().encode(FeedbinCreateSubscription(feedURL: url))
		} catch {
			completion(.failure(error))
			return
		}
		
		transport.send(request: request, method: HTTPMethod.post, payload: payload) { result in
			
			switch result {
			case .success(let (response, data)):
				
				switch response.forcedStatusCode {
				case 201:
					guard let subData = data else {
						completion(.failure(TransportError.noData))
						break
					}
					do {
						let subscription = try JSONDecoder().decode(FeedbinSubscription.self, from: subData)
						completion(.success(.created(subscription)))
					} catch {
						completion(.failure(error))
					}
				case 300:
					guard let subData = data else {
						completion(.failure(TransportError.noData))
						break
					}
					do {
						let subscriptions = try JSONDecoder().decode([FeedbinSubscriptionChoice].self, from: subData)
						completion(.success(.multipleChoice(subscriptions)))
					} catch {
						completion(.failure(error))
					}
				case 302:
					completion(.success(.alreadySubscribed))
				default:
					completion(.failure(TransportError.httpError(status: response.forcedStatusCode)))
				}
				
			case .failure(let error):
				
				switch error {
				case TransportError.httpError(let status):
					switch status {
					case 401:
						// I don't know why we get 401's here.  This looks like a Feedbin bug, but it only happens
						// when you are already subscribed to the feed.
						completion(.success(.alreadySubscribed))
					case 404:
						completion(.success(.notFound))
					default:
						completion(.failure(error))
					}
				default:
					completion(.failure(error))
				}
				
			}
			
		}
		
	}
	
	func renameSubscription(subscriptionID: String, newName: String, completion: @escaping (Result<Void, Error>) -> Void) {
		let callURL = feedbinBaseURL.appendingPathComponent("subscriptions/\(subscriptionID)/update.json")
		let request = URLRequest(url: callURL, credentials: credentials)
		let payload = FeedbinUpdateSubscription(title: newName)
		transport.send(request: request, method: HTTPMethod.post, payload: payload, completion: completion)
	}
	
	func deleteSubscription(subscriptionID: String, completion: @escaping (Result<Void, Error>) -> Void) {
		let callURL = feedbinBaseURL.appendingPathComponent("subscriptions/\(subscriptionID).json")
		let request = URLRequest(url: callURL, credentials: credentials)
		transport.send(request: request, method: HTTPMethod.delete, completion: completion)
	}
	
	func retrieveTaggings(completionHandler completion: @escaping (Result<[FeedbinTagging]?, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("taggings.json")
		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.taggings]
		let request = URLRequest(url: callURL, credentials: credentials, conditionalGet: conditionalGet)
		
		transport.send(request: request, resultType: [FeedbinTagging].self) { [weak self] result in
			
			switch result {
			case .success(let (response, taggings)):
				self?.storeConditionalGet(key: ConditionalGetKeys.taggings, headers: response.allHeaderFields)
				completion(.success(taggings))
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}
	
	func createTagging(feedID: Int, name: String, completion: @escaping (Result<Int, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("taggings.json")
		var request = URLRequest(url: callURL, credentials: credentials)
		request.addValue("application/json; charset=utf-8", forHTTPHeaderField: HTTPRequestHeader.contentType)

		let payload: Data
		do {
			payload = try JSONEncoder().encode(FeedbinCreateTagging(feedID: feedID, name: name))
		} catch {
			completion(.failure(error))
			return
		}
		
		transport.send(request: request, method: HTTPMethod.post, payload:payload) { result in
			
			switch result {
			case .success(let (response, _)):
				if let taggingLocation = response.valueForHTTPHeaderField(HTTPResponseHeader.location),
					let lowerBound = taggingLocation.range(of: "v2/taggings/")?.upperBound,
					let upperBound = taggingLocation.range(of: ".json")?.lowerBound,
					let taggingID = Int(taggingLocation[lowerBound..<upperBound]) {
						completion(.success(taggingID))
				} else {
					completion(.failure(TransportError.noData))
				}
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}

	func deleteTagging(taggingID: String, completion: @escaping (Result<Void, Error>) -> Void) {
		let callURL = feedbinBaseURL.appendingPathComponent("taggings/\(taggingID).json")
		var request = URLRequest(url: callURL, credentials: credentials)
		request.addValue("application/json; charset=utf-8", forHTTPHeaderField: HTTPRequestHeader.contentType)
		transport.send(request: request, method: HTTPMethod.delete, completion: completion)
	}
	
	func retrieveIcons(completionHandler completion: @escaping (Result<[FeedbinIcon]?, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("icons.json")
		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.icons]
		let request = URLRequest(url: callURL, credentials: credentials, conditionalGet: conditionalGet)
		
		transport.send(request: request, resultType: [FeedbinIcon].self) { [weak self] result in
			
			switch result {
			case .success(let (response, icons)):
				self?.storeConditionalGet(key: ConditionalGetKeys.icons, headers: response.allHeaderFields)
				completion(.success(icons))
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}
	
	func retrieveEntries(feedID: String, completion: @escaping (Result<([FeedbinEntry]?, String?), Error>) -> Void) {
		
		let since = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
		let sinceString = FeedbinDate.formatter.string(from: since)
		
		var callURL = URLComponents(url: feedbinBaseURL.appendingPathComponent("/feeds/\(feedID)/entries.json"), resolvingAgainstBaseURL: false)!
		callURL.queryItems = [URLQueryItem(name: "since", value: sinceString), URLQueryItem(name: "per_page", value: "100")]
		let request = URLRequest(url: callURL.url!, credentials: credentials)
		
		transport.send(request: request, resultType: [FeedbinEntry].self) { result in
			
			switch result {
			case .success(let (response, entries)):
				
				let pagingInfo = HTTPLinkPagingInfo(urlResponse: response)
				completion(.success((entries, pagingInfo.nextPage)))
				
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}

	func retrieveEntries(completion: @escaping (Result<([FeedbinEntry]?, String?), Error>) -> Void) {
		
		let since: Date = {
			if let lastArticleFetch = accountMetadata?.lastArticleFetch {
				return lastArticleFetch
			} else {
				return Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
			}
		}()
		
		let sinceString = FeedbinDate.formatter.string(from: since)
		var callURL = URLComponents(url: feedbinBaseURL.appendingPathComponent("entries.json"), resolvingAgainstBaseURL: false)!
		callURL.queryItems = [URLQueryItem(name: "since", value: sinceString), URLQueryItem(name: "per_page", value: "100")]
		let request = URLRequest(url: callURL.url!, credentials: credentials)
		
		transport.send(request: request, resultType: [FeedbinEntry].self) { [weak self] result in
			
			switch result {
			case .success(let (response, entries)):
				
				let dateInfo = HTTPDateInfo(urlResponse: response)
				self?.accountMetadata?.lastArticleFetch = dateInfo?.date

				let pagingInfo = HTTPLinkPagingInfo(urlResponse: response)
				completion(.success((entries, pagingInfo.nextPage)))
				
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}
	
	func retrieveEntries(page: String, completion: @escaping (Result<([FeedbinEntry]?, String?), Error>) -> Void) {
		
		guard let callURL = URL(string: page) else {
			completion(.success((nil, nil)))
			return
		}
		
		let request = URLRequest(url: callURL, credentials: credentials)

		transport.send(request: request, resultType: [FeedbinEntry].self) { result in
			
			switch result {
			case .success(let (response, entries)):
				
				let pagingInfo = HTTPLinkPagingInfo(urlResponse: response)
				completion(.success((entries, pagingInfo.nextPage)))

			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}

	func retrieveUnreadEntries(completionHandler completion: @escaping (Result<[Int]?, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("unread_entries.json")
		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.unreadEntries]
		let request = URLRequest(url: callURL, credentials: credentials, conditionalGet: conditionalGet)
		
		transport.send(request: request, resultType: [Int].self) { [weak self] result in
			
			switch result {
			case .success(let (response, unreadEntries)):
				self?.storeConditionalGet(key: ConditionalGetKeys.unreadEntries, headers: response.allHeaderFields)
				completion(.success(unreadEntries))
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}
	
	func retrieveStarredEntries(completionHandler completion: @escaping (Result<[Int]?, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("starred_entries.json")
		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.starredEntries]
		let request = URLRequest(url: callURL, credentials: credentials, conditionalGet: conditionalGet)
		
		transport.send(request: request, resultType: [Int].self) { [weak self] result in
			
			switch result {
			case .success(let (response, starredEntries)):
				self?.storeConditionalGet(key: ConditionalGetKeys.starredEntries, headers: response.allHeaderFields)
				completion(.success(starredEntries))
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}
	
}

// MARK: Private

extension FeedbinAPICaller {
	
	func storeConditionalGet(key: String, headers: [AnyHashable : Any]) {
		if var conditionalGet = accountMetadata?.conditionalGetInfo {
			conditionalGet[key] = HTTPConditionalGetInfo(headers: headers)
			accountMetadata?.conditionalGetInfo = conditionalGet
		}
	}
	
}