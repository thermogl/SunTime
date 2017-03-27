import Cocoa
import CoreLocation
import RxSwift
import RxCocoa

fileprivate typealias DateResult = (sunrise: Date, sunset: Date)

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

	@IBOutlet weak var window: NSWindow!
	
	private lazy var statusItem: NSStatusItem = {
		let statusItem = NSStatusBar.system().statusItem(withLength: NSVariableStatusItemLength)
		
		let statusItemMenu = NSMenu()
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
	
	fileprivate lazy var locationSubject: PublishSubject<CLLocation> = {
		return PublishSubject<CLLocation>()
	}()
	
	fileprivate lazy var updateSubject: PublishSubject<Bool> = {
		return PublishSubject<Bool>()
	}()

	func applicationDidFinishLaunching(_ aNotification: Notification) {
		self.getTimes()
	}
	
	private var publishSubjectBag = DisposeBag()
	private var locationBag = DisposeBag()
	
	func getTimes() {
		
		let combined = Observable.combineLatest(self.locationSubject.asObservable(), self.updateSubject.asObservable().startWith(true)) { ($0, $1) }
		combined.debounce(1.0, scheduler: MainScheduler.instance).flatMap {[unowned self] (location, update) -> Observable<DateResult> in
			return self.sunriseSunsetJSONObservable(for: location).flatMap { json  -> Observable<DateResult> in
				
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
		.subscribe(onNext: {[unowned self] result in
			
			let relevantDate = self.updateStatusItemFrom(sunrise: result.sunrise, sunset: result.sunset)
			
			let timeUntilNextEvent = relevantDate.timeIntervalSinceNow + 10
			DispatchQueue.main.asyncAfter(deadline: .now() + timeUntilNextEvent) {
				self.updateSubject.onNext(true)
			}
			
		}).addDisposableTo(self.locationBag)
		
		self.locationManager.startUpdatingLocation()
	}
	
	func updateStatusItemFrom(sunrise: Date, sunset: Date) -> Date {
		
		if sunrise > Date() {
			let sunriseString = self.humanDateFormatter.string(from: sunrise)
			self.statusItem.title = "☀️ \(sunriseString)"
			return sunrise
		}
		else if sunset > Date() {
			let sunsetString = self.humanDateFormatter.string(from: sunset)
			self.statusItem.title = "🌑 \(sunsetString)"
			return sunset
		}
		
		return Date()
	}
	
	func sunriseSunsetJSONObservable(for location: CLLocation) -> Observable<Any> {
		
		let lat = location.coordinate.latitude
		let long = location.coordinate.longitude
		
		let urlString = "http://api.sunrise-sunset.org/json?lat=\(lat)&lng=\(long)&date=today&formatted=0"
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
