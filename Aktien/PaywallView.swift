//
//  PaywallView.swift
//  Aktien
//
//  Paywall: 7 Tage kostenlos, danach 9,99 €/Monat. Rechtstext gemäß App Store.
//  Gilt für iPhone, iPad und (falls Zielplattform) Mac – keine Geräte-Einschränkung.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @State private var subscriptionManager = SubscriptionManager.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            paywallContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Zurück") {
                            StartState.shared.hasStarted = false
                        }
                    }
                }
        }
    }

    /// Max. Breite des Inhalts auf iPad/Mac, damit die Lesbarkeit gut bleibt.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 480 : nil
    }

    private var paywallContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Aktien Premium")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    if subscriptionManager.isInFreeTrialPeriod {
                        Text("Noch \(subscriptionManager.trialRemainingDays) Tag\(subscriptionManager.trialRemainingDays == 1 ? "" : "e") kostenlos")
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("1 Woche kostenlos testen")
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }

                    Text("1 Woche kostenlos: Testen Sie in Ruhe, ob die App für Sie passt. In der Testwoche wird nichts berechnet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Text("Danach 9,99 € pro Monat. Jederzeit kündbar.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if let product = subscriptionManager.monthlyProduct {
                        VStack(spacing: 4) {
                            Text(product.displayPrice)
                                .font(.title)
                                .fontWeight(.semibold)
                            Text("Laufzeit: 1 Monat")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Wenn zu viele Kursziele nicht ermittelt werden konnten, sollten Sie überlegen, sich API-Keys von OpenAI oder FMP zu besorgen und diese in den Einstellungen einzutragen. Unter Einstellungen können Sie die Verbindung testen; danach „Kursziele ermitteln“ ausführen.")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.72, green: 0.55, blue: 0))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.yellow.opacity(0.25))
                        .cornerRadius(8)

                    legalText
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                    legalLinks
                        .padding(.top, 12)
                        .padding(.horizontal, 24)
                }
                .padding(.vertical, 24)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)

            VStack(spacing: 10) {
                if let msg = subscriptionManager.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                }
                Button {
                    Task { await subscriptionManager.purchase() }
                } label: {
                    HStack {
                        if subscriptionManager.isPurchasing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(subscriptionManager.isInFreeTrialPeriod ? "Kostenlos testen" : "Jetzt abonnieren")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(subscriptionManager.isPurchasing || subscriptionManager.isLoadingProducts)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .background(.bar)
        }
        .task {
            await subscriptionManager.loadProducts()
        }
    }

    private var legalText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Das Abonnement verlängert sich automatisch, sofern es nicht mindestens 24 Stunden vor Ende des Abrechnungszeitraums gekündigt wird.")
            Text("Die Verwaltung des Abos und die Kündigung erfolgen in den Einstellungen deines Apple-ID-Kontos nach dem Kauf.")
        }
    }

    /// Datenschutz- und Nutzungsbedingungen-URLs (wie unter Rechtliches in der App)
    private static let datenschutzURL = URL(string: "https://kisoft4you.com/datenschutzerklaerung")!
    private static let nutzungsbedingungenURL = URL(string: "https://kisoft4you.com/agb")!

    private var legalLinks: some View {
        HStack(spacing: 20) {
            Link("Datenschutz", destination: Self.datenschutzURL)
                .font(.caption2)
            Link("Nutzungsbedingungen", destination: Self.nutzungsbedingungenURL)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
    }
}

#Preview {
    PaywallView()
}
