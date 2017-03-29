import Cocoa
import CoreLocation
import RxSwift
import RxCocoa

fileprivate typealias DateResult = (sunrise: Date, sunset: Date)

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
	
	private lazy var statusItem: NSStatusItem = {
		let statusItem = NSStatusBar.system().statusItem(withLength: NSVariableStatusItemLength)
		
		let statusItemMenu = NSMenu()
		statusItemMenu.addItem(withTitle: "Refresh", action: #selector(getTimes), keyEquivalent: "r").target = self
		statusItemMenu.addItem(NSMenuItem.separator())
		statusItemMenu.addItem(withTitle: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q").target = NSApp
		statusItem.menu = statusItemMenu
		
		return statusItem
	}()
	
	private lazy var session: URLSession = {
		return URLSession(configuration: URLSessionConfiguration.default)
	}()
	
	private lazy var locationManager: CLLocationManager = {
		let locationManager = CLLocationManager()
		locationManager.delegate = self
		locationManager.distanceFilter = 1000
		return locationManager
	}()
	
	private lazy var jsonDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
		return formatter
	}()
	
	private lazy var humanDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.timeStyle = .short
		return formatter
	}()
	
	private lazy var requestFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()
	
	fileprivate lazy var locationSubject: PublishSubject<CLLocation> = {
		return PublishSubject<CLLocation>()
	}()
	
	fileprivate lazy var dateSubject: PublishSubject<Date?> = {
		return PublishSubject<Date?>()
	}()

	func applicationDidFinishLaunching(_ aNotification: Notification) {
		self.getTimes()
	}
	
	private var publishSubjectBag = DisposeBag()
	private var locationBag = DisposeBag()
	
	@objc private func getTimes() {
		
		let locationObservable = self.locationSubject.asObservable()
		let dateObservable = self.dateSubject.asObservable().startWith(Date()).do(onNext: {[unowned self] _ in
			self.locationManager.startUpdatingLocation()
		})
		
		let combined = Observable.combineLatest(locationObservable, dateObservable) { ($0, $1) }
		combined.debounce(1.0, scheduler: MainScheduler.instance).flatMap {[unowned self] (location, date) -> Observable<DateResult> in
			
			guard let date = date else { return .empty() }
			
			return self.sunriseSunsetJSONObservable(for: location, date: date).flatMap { json  -> Observable<DateResult> in
				
				guard let json = json as? [String: Any] else { return .empty() }
				guard let results = json["results"] as? [String: Any] else { return .empty() }
				
				guard let sunrise = results["sunrise"] as? String else { return .empty() }
				guard let sunset = results["sunset"] as? String else { return .empty() }
				
				guard let sunriseDate = self.jsonDateFormatter.date(from: sunrise) else { return .empty() }
				guard let sunsetDate = self.jsonDateFormatter.date(from: sunset) else { return .empty() }
				
				let result: DateResult = (sunrise: sunriseDate, sunset: sunsetDate)
				return .just(result)
			}
		}
		.observeOn(MainScheduler.instance)
		.subscribe(onNext: {[unowned self] result in
			
			self.locationManager.stopUpdatingLocation()
			
			let relevantDate = self.updateStatusItemFrom(sunrise: result.sunrise, sunset: result.sunset)
			let now = Date()
			let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)
			
			let timeUntilNextEvent = relevantDate.timeIntervalSinceNow
			
			if timeUntilNextEvent < 0 {
				self.dateSubject.onNext(tomorrow)
			}
			else {
				
				var nextDate = now
				if relevantDate == result.sunset {
					if let tomorrow = tomorrow {
						nextDate = tomorrow
					}
				}
				
				DispatchQueue.main.asyncAfter(deadline: .now() + timeUntilNextEvent + 10) {
					self.dateSubject.onNext(nextDate)
				}
			}
			
		}).addDisposableTo(self.locationBag)
	}
	
	private func updateStatusItemFrom(sunrise: Date, sunset: Date) -> Date {
		
		if sunrise > Date() {
			let sunriseString = self.humanDateFormatter.string(from: sunrise)
			self.statusItem.title = "☀️ \(sunriseString)"
			return sunrise
		}
		else {
			let sunsetString = self.humanDateFormatter.string(from: sunset)
			self.statusItem.title = "🌑 \(sunsetString)"
			return sunset
		}
	}
	
	private func sunriseSunsetJSONObservable(for location: CLLocation, date: Date) -> Observable<Any> {
		
		let lat = location.coordinate.latitude
		let long = location.coordinate.longitude
		
		let dateString = self.requestFormatter.string(from: date)
		let urlString = "http://api.sunrise-sunset.org/json?lat=\(lat)&lng=\(long)&date=\(dateString)&formatted=0"
		guard let url = URL(string: urlString) else { return .empty() }
		let request = URLRequest(url: url)
		return self.session.rx.json(request: request)
	}
}

extension AppDelegate: CLLocationManagerDelegate {
	
	func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		guard let lastLocation = locations.last else { return }
		self.locationSubject.onNext(lastLocation)
	}
}
