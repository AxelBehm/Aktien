//
//  PaywallView.swift
//  Aktien
//
//  Paywall: 7 Tage kostenlos, danach 9,99 €/Monat. Rechtstext gemäß App Store.
//  Gilt für iPhone, iPad und (falls Zielplattform) Mac – keine Geräte-Einschränkung.
//

import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct PaywallView: View {
    @State private var subscriptionManager = SubscriptionManager.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(iOS)
    @State private var safariURL: URL?
    #endif

    var body: some View {
        NavigationStack {
            paywallContent
                .navigationTitle("Aktien-Kursziele")
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
                    // Guideline 3.1.2(c): Apple verlangt exakt "Title of publication or service" in der App.
                    Text("Title of publication or service: Aktien Premium")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
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

                    // Laufzeit, Preis und Rechtstexte transparent auf der Paywall.
                    VStack(spacing: 6) {
                        if let product = subscriptionManager.monthlyProduct {
                            Text(product.displayName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(product.displayPrice)
                                .font(.title)
                                .fontWeight(.semibold)
                            Text("Laufzeit: 1 Monat (automatisch verlängerbar). Jederzeit kündbar.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Aktien Premium (monatlich)")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("9,99 € / Monat")
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text("Laufzeit: 1 Monat. Jederzeit kündbar.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

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
                if subscriptionManager.isInFreeTrialPeriod {
                    Button {
                        NotificationCenter.default.post(name: .paywallTrialAcknowledged, object: nil)
                    } label: {
                        Text("Weiter – App nutzen")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Button {
                    // Direkt den StoreKit-Kaufdialog starten (stabiler im Review als zusätzlicher Zwischen-Sheet-Schritt).
                    Task { await subscriptionManager.purchase() }
                } label: {
                    HStack {
                        Text(subscriptionManager.isInFreeTrialPeriod ? "Kostenlos testen" : "Jetzt abonnieren")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(subscriptionManager.isInFreeTrialPeriod ? Color.accentColor.opacity(0.7) : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(subscriptionManager.isPurchasing)
                Button {
                    Task { await subscriptionManager.restore() }
                } label: {
                    HStack {
                        if subscriptionManager.isPurchasing {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("Käufe wiederherstellen")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .disabled(subscriptionManager.isPurchasing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .background(.bar)
        }
        .task {
            await subscriptionManager.loadProducts()
        }
        #if os(iOS)
        .sheet(item: $safariURL) { url in
            SafariView(url: url)
        }
        #endif
    }

    private var legalText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Das Abonnement verlängert sich automatisch, sofern es nicht mindestens 24 Stunden vor Ende des Abrechnungszeitraums gekündigt wird.")
            Text("Die Verwaltung des Abos und die Kündigung erfolgen in den Einstellungen deines Apple-ID-Kontos nach dem Kauf.")
        }
    }

    /// Richtlinie 3.1.2(c): Funktionale Links zu Datenschutzerklärung und EULA im Kaufprozess
    private static let datenschutzURL = URL(string: "https://axelbehm.github.io/kisoft4you/datenschutz.html")!
    /// Standard-EULA von Apple (App Store Terms of Use)
    private static let nutzungsbedingungenURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    private var legalLinks: some View {
        VStack(spacing: 10) {
            Text("Datenschutz & Nutzungsbedingungen")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Button {
                    #if os(iOS)
                    safariURL = Self.datenschutzURL
                    #elseif os(macOS)
                    NSWorkspace.shared.open(Self.datenschutzURL)
                    #endif
                } label: {
                    Text("Datenschutzerklärung")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                Button {
                    #if os(iOS)
                    safariURL = Self.nutzungsbedingungenURL
                    #elseif os(macOS)
                    NSWorkspace.shared.open(Self.nutzungsbedingungenURL)
                    #endif
                } label: {
                    Text("Nutzungsbedingungen (EULA)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
    }
}

#Preview {
    PaywallView()
}
