Name:		golang
Version:	v1.8.3
Release:	1%{?dist}
Summary:	Go install from source
Group:		Fake
License:	BSD
BuildRoot:	%(mktemp -ud %{_tmppath}/%{name}-%{version}-%{release}-XXXXXX)
Provides:	golang
BuildArch:	noarch
%description
%{summary}
%prep
%setup -c -T
%build
%install
%files
%defattr(-,root,root,-)
%changelog
* Wed Jun 06 2018 Jan Chaloupka <jchaloup@redhat.com> 0.0-1
- Initial change
EOF
