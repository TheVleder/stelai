// WeatherService.swift
// StyleAI — Weather Data Service
//
// Fetches current weather from Open-Meteo (free, no API key).
// Uses CoreLocation for device coordinates, falls back to Madrid.

import Foundation
import CoreLocation

// MARK: - Weather Data

/// Structured weather snapshot.
struct WeatherData: Sendable {
    let temperature: Double        // °C
    let apparentTemperature: Double // °C (feels like)
    let weatherCode: Int           // WMO code
    let windSpeed: Double          // km/h
    let humidity: Int              // %
    let isDay: Bool
    let locationName: String

    /// Human-readable condition from WMO weather code.
    var condition: String {
        switch weatherCode {
        case 0:           return "Despejado"
        case 1:           return "Mostly Clear"
        case 2:           return "Parcialmente Nublado"
        case 3:           return "Nublado"
        case 45, 48:      return "Niebla"
        case 51, 53, 55:  return "Llovizna"
        case 56, 57:      return "Llovizna Helada"
        case 61, 63, 65:  return "Lluvia"
        case 66, 67:      return "Lluvia Helada"
        case 71, 73, 75:  return "Nieve"
        case 77:          return "Granizo"
        case 80, 81, 82:  return "Chubascos"
        case 85, 86:      return "Nevada"
        case 95:          return "Tormenta"
        case 96, 99:      return "Tormenta con Granizo"
        default:          return "Desconocido"
        }
    }

    /// SF Symbol name for the current weather.
    var symbolName: String {
        switch weatherCode {
        case 0:
            return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1:
            return isDay ? "sun.min.fill" : "moon.fill"
        case 2:
            return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51, 53, 55, 56, 57:
            return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67:
            return "cloud.rain.fill"
        case 71, 73, 75, 77:
            return "cloud.snow.fill"
        case 80, 81, 82:
            return "cloud.heavyrain.fill"
        case 85, 86:
            return "cloud.snow.fill"
        case 95, 96, 99:
            return "cloud.bolt.rain.fill"
        default:
            return "questionmark.circle"
        }
    }

    /// Target thermal index for outfit matching (0.0 = very cold gear, 1.0 = very light).
    var targetThermalIndex: Double {
        switch apparentTemperature {
        case ..<0:      return 0.05
        case 0..<5:     return 0.10
        case 5..<10:    return 0.20
        case 10..<15:   return 0.30
        case 15..<20:   return 0.45
        case 20..<25:   return 0.60
        case 25..<30:   return 0.75
        case 30..<35:   return 0.85
        default:        return 0.95
        }
    }
}

// MARK: - Location Manager

/// Minimal location wrapper for one-shot coordinate fetch.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    func requestLocation() async -> CLLocationCoordinate2D? {
        return await withCheckedContinuation { cont in
            self.continuation = cont
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            manager.requestWhenInUseAuthorization()
            manager.requestLocation()

            // Timeout after 5 seconds
            Task {
                try? await Task.sleep(for: .seconds(5))
                if let pending = self.continuation {
                    self.continuation = nil
                    pending.resume(returning: nil)
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coord = locations.first?.coordinate
        Task { @MainActor in
            continuation?.resume(returning: coord)
            continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
}

// MARK: - Weather Service

/// Fetches weather from Open-Meteo free API.
@MainActor
@Observable
final class WeatherService {

    static let shared = WeatherService()

    private(set) var currentWeather: WeatherData?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let locationProvider = LocationProvider()

    /// Default coordinates: Madrid, Spain
    private let defaultLat = 40.4168
    private let defaultLon = -3.7038
    private let defaultCity = "Madrid"

    private init() {}

    /// Fetch current weather. Uses device location if available, else Madrid.
    func fetchWeather() async {
        isLoading = true
        errorMessage = nil

        DebugLogger.shared.log("🌤 Fetching weather...", level: .info)

        let coord = await locationProvider.requestLocation()
        let lat = coord?.latitude ?? defaultLat
        let lon = coord?.longitude ?? defaultLon
        let city = coord != nil ? "Tu Ubicación" : defaultCity

        DebugLogger.shared.log("📍 Using coordinates: \(lat), \(lon) (\(city))", level: .info)

        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,is_day&timezone=auto"

        guard let url = URL(string: urlString) else {
            errorMessage = "URL inválida"
            isLoading = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
                throw WeatherError.httpError(httpResp.statusCode)
            }

            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let current = decoded.current

            currentWeather = WeatherData(
                temperature: current.temperature_2m,
                apparentTemperature: current.apparent_temperature,
                weatherCode: current.weather_code,
                windSpeed: current.wind_speed_10m,
                humidity: current.relative_humidity_2m,
                isDay: current.is_day == 1,
                locationName: city
            )

            isLoading = false
            DebugLogger.shared.log("✅ Weather: \(current.temperature_2m)°C, code \(current.weather_code)", level: .success)
        } catch {
            errorMessage = "Error al obtener el clima: \(error.localizedDescription)"
            isLoading = false
            DebugLogger.shared.log("❌ Weather fetch failed: \(error.localizedDescription)", level: .error)
        }
    }
}

// MARK: - Errors

enum WeatherError: LocalizedError {
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Error HTTP \(code)"
        }
    }
}

// MARK: - Open-Meteo JSON Models

private struct OpenMeteoResponse: Decodable {
    let current: CurrentWeather
}

private struct CurrentWeather: Decodable {
    let temperature_2m: Double
    let relative_humidity_2m: Int
    let apparent_temperature: Double
    let weather_code: Int
    let wind_speed_10m: Double
    let is_day: Int
}
