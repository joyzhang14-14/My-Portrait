import SwiftUI

struct Sidebar: View {
    @Binding var selection: SidebarSection

    var body: some View {
        VStack(spacing: 0) {
            // top icon row
            HStack(spacing: 10) {
                IconButton(systemName: "sidebar.left")
                IconButton(systemName: "magnifyingglass")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 22)

            // title
            HStack {
                Text("My Portrait")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
            }
            .padding(.horizontal, 18)

            // status icons row (placeholder for screen + notification + phone)
            HStack(spacing: 14) {
                Image(systemName: "display").font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.65))
                Text("|").foregroundStyle(.white.opacity(0.18))
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell").font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.65))
                    Text("9+")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.red))
                        .offset(x: 8, y: -6)
                }
                Image(systemName: "phone").font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 16)

            // new chat button
            Button { selection = .home } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("New chat").font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.02)))
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            // nav items
            VStack(spacing: 1) {
                ForEach(SidebarSection.allCases.filter { $0 != .home }) { section in
                    NavRow(section: section, active: selection == section) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, 8)

            // recents
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "chevron.down").font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("RECENTS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 22)
                .padding(.bottom, 6)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Mock.recents, id: \.self) { title in
                            HStack(spacing: 8) {
                                Image(systemName: "circle")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.white.opacity(0.45))
                                Text(title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // settings
            Button { } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").font(.system(size: 13))
                    Text("Settings").font(.system(size: 13))
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 250)
        .background(Color.black)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
        }
    }
}

private struct NavRow: View {
    let section: SidebarSection
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18, alignment: .center)
                Text(section.label)
                    .font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(active ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct IconButton: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.55))
    }
}
