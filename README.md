# 👗 Style AI

**Tu estilista personal con inteligencia artificial — 100% local y privado.**

Style AI es una app de moda premium para iOS 26 que convierte tu iPhone en un asistente de estilo inteligente. Utiliza el framework **Vision** de Apple para procesamiento de IA completamente on-device — sin servidores, sin subir fotos, sin descargas de modelos pesados.

---

## ✨ Tres Pilares

### 1. 📸 Escáner de Armario Inteligente
Sube una foto de tu prenda y la IA la analiza automáticamente:
- **Clasificación automática** — detecta tipo (camiseta, pantalón, calzado, etc.) usando `VNClassifyImageRequest`
- **Índice térmico** — estima si la prenda es para frío, templado o calor
- **Etiquetas de estilo** — sugiere tags como "Casual", "Formal", "Deportivo"
- **Color dominante** — extrae el color principal vía `CIAreaAverage`
- Todo se guarda en **SwiftData** con thumbnails, embeddings vectoriales y metadatos

### 2. 🪞 Probador Virtual (VTO)
Pruébate ropa sobre tu foto con IA real:
- **Segmentación de persona** — `VNGeneratePersonSegmentationRequest` crea una máscara pixel-accurate del cuerpo
- **Dos modos de renderizado:**
  - **Preview rápido** (~200ms) — overlay visual con gradientes sobre la silueta detectada
  - **Generación IA** (~15s) — **Stable Diffusion inpainting** on-device para resultado foto-realista
- **Modelo descargable** — el motor SD (~2 GB) se descarga de Hugging Face al primer uso
- **Selector de prendas** — carrusel horizontal para tops, bottoms y calzado
- **Fallback inteligente** — si no detecta persona, usa composición por rectángulos

### 3. 🌤️ Estilista Meteorológico
Outfits inteligentes basados en el clima:
- Consulta el **clima local** vía WeatherKit
- Cruza temperatura con el **índice térmico** de tus prendas
- Genera **recomendaciones de outfit** con puntuación de compatibilidad
- Notificaciones push matutinas con sugerencias

---

## 🏗️ Arquitectura

```
StyleAI/
├── App/
│   └── AppEntry.swift              # @main, SwiftData, lifecycle, notificaciones
├── Core/
│   ├── VisionAIService.swift       # 🧠 Vision AI (segmentación, clasificación, color)
│   ├── ModelManager.swift          # Motor de IA — bootstrap y estado
│   ├── TryOnEngine.swift           # Pipeline de composición VTO
│   ├── OutfitRecommender.swift     # Lógica de recomendación de outfits
│   ├── WeatherService.swift        # Integración con WeatherKit
│   └── DeviceChecker.swift         # Validación de hardware (A17+)
├── Models/
│   ├── WardrobeItem.swift          # @Model SwiftData con embeddings
│   ├── SampleGarments.swift        # Catálogo demo de prendas
│   └── GarmentSlot.swift           # Slots de cuerpo (top/bottom/shoes)
├── Views/
│   ├── ContentView.swift           # Pantalla principal + estado del motor
│   ├── ScannerView.swift           # Escáner con IA auto-clasificación
│   ├── TryOnView.swift             # Probador virtual interactivo
│   ├── WeatherStylistView.swift    # Estilista meteorológico
│   ├── CarouselPickerView.swift    # Selector horizontal de prendas
│   └── DebugConsole.swift          # 🐛 HUD flotante (Easter Egg: 5 taps)
├── Design/
│   └── DesignTokens.swift          # Sistema de diseño "Liquid Glass"
└── Assets.xcassets/                # Iconos y colores
```

---

## 🧠 IA On-Device

| Capacidad | API / Modelo | Uso |
|---|---|---|
| **Segmentación de persona** | `VNGeneratePersonSegmentationRequest` | Máscara corporal para VTO |
| **Clasificación de imagen** | `VNClassifyImageRequest` | Tipo de prenda, etiquetas |
| **Extracción de color** | `CIAreaAverage` | Color dominante |
| **Generación de imagen** | Stable Diffusion 2.1 (CoreML) | VTO foto-realista por inpainting |

- **Vision AI** (built-in) — segmentación + clasificación, sin descargas, ~1s init
- **Stable Diffusion** (descargable, ~2 GB) — modelo de `apple/coreml-stable-diffusion-2-1-base` de Hugging Face, se descarga al primer uso del VTO

---

## 🛠️ Stack Tecnológico

| Componente | Tecnología |
|---|---|
| **OS mínimo** | iOS 26.0 |
| **Lenguaje** | Swift 6.2 (Strict Concurrency) |
| **UI** | SwiftUI con diseño "Liquid Glass" |
| **Persistencia** | SwiftData |
| **IA (Vision)** | Vision Framework (on-device, built-in) |
| **IA (Generativa)** | CoreML Stable Diffusion 2.1 (on-device, descargable) |
| **SPM** | `apple/ml-stable-diffusion` ≥ 1.1.1 |
| **Clima** | WeatherKit / CoreLocation |
| **Build** | XcodeGen (`project.yml`) |
| **CI/CD** | GitHub Actions → `.ipa` sin firmar |

---

## 🔧 Estrategia "Hacker"

Este proyecto está diseñado para desarrollo sin Mac física:

- **Shell App ligera** (<30 MB) para Sideloading vía AltStore
- **Sin modelos externos** — Vision AI está integrada en iOS
- **Debugging ciego** — consola de debug flotante integrada (5 toques en el logo)
- **Code signing deshabilitado** — para compilar sin Apple Developer Account
- **GitHub Actions** — compila `.ipa` automáticamente en la nube

---

## 📱 Requisitos de Hardware

- **iPhone con A17 Pro o superior** — Neural Engine potente necesario
- **iOS 26.0+**
- **~200 MB** de almacenamiento en device

---

## 🚀 Cómo Compilar

### Opción 1: XcodeGen Local
```bash
# Instalar XcodeGen
brew install xcodegen

# Generar proyecto Xcode
cd "Style AI"
xcodegen generate

# Abrir y compilar
open StyleAI.xcodeproj
```

### Opción 2: GitHub Actions (Sin Mac)
Cada push a `main` genera un `.ipa` automáticamente:
1. Push al repositorio
2. GitHub Actions compila con `xcodebuild`
3. Descarga el artefacto `StyleAI.ipa` desde Actions
4. Sideload con AltStore

---

## 🎨 Sistema de Diseño

**"Liquid Glass"** — UI premium con estética 2026:

- **Fondo oscuro** con gradientes sutiles
- **Glassmorphism** — tarjetas con `ultraThinMaterial` y bordes luminosos
- **Gradientes de marca** — rosa/dorado para acciones principales
- **Tipografía SF Pro** — peso semibold para títulos, monospace para datos
- **Micro-animaciones** — springs, transiciones numéricas, shimmer loading
- **Modo oscuro nativo** — diseñado dark-first

---

## 🐛 Debug Console (Easter Egg)

Toca **5 veces** el icono de la app en la pantalla principal para activar la consola flotante:

- 📋 Log de eventos en tiempo real (color-coded por nivel)
- 📊 Métricas de RAM, CPU y device
- 🔄 Reinicializar motor de IA
- 🗑️ Limpiar datos de SwiftData
- 📤 Exportar logs

La consola es **arrastrable** y se puede colapsar.

---

## 📂 Permisos Requeridos

| Permiso | Razón |
|---|---|
| 📷 Cámara | Escanear prendas |
| 🖼️ Fotos (lectura) | Seleccionar fotos para VTO y escáner |
| 🖼️ Fotos (escritura) | Guardar looks generados |
| 📍 Ubicación | Obtener clima local para recomendaciones |
| 🔔 Notificaciones | Sugerencias matutinas de outfit |

---

## 📋 Estado del Proyecto

### ✅ Implementado
- [x] Escáner de prendas con IA auto-clasificación
- [x] Probador Virtual con segmentación de persona real
- [x] Estilista Meteorológico con WeatherKit
- [x] Sistema de diseño "Liquid Glass" completo
- [x] SwiftData persistencia con embeddings vectoriales
- [x] Debug Console flotante con Easter Egg
- [x] Motor de IA con bootstrap instantáneo
- [x] Gestión de memoria (descarga en background)
- [x] GitHub Actions CI/CD
- [x] Notificaciones push habilitadas

### 🔮 Roadmap
- [ ] Inpainting real de prendas (rellenar huecos del cuerpo)
- [ ] IA generativa (Stable Diffusion / ControlNet) para VTO foto-realista
- [ ] Búsqueda semántica por embeddings vectoriales
- [ ] Compartir looks generados en redes sociales
- [ ] Widget de iOS con outfit del día
- [ ] Soporte para Apple Watch (notificaciones enriquecidas)

---

## 📄 Licencia

Proyecto privado. Todos los derechos reservados.
